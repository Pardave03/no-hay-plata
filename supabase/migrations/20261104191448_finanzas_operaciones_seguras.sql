-- Incremental: usa las seis tablas existentes. No reconstruye ni borra datos.
-- Este modelo requiere que todavía no existan operaciones financieras previas.
set lock_timeout = '5s';

do $$
begin
  if exists (select 1 from public.cuentas)
     or exists (select 1 from public.movimientos)
     or exists (select 1 from public.asignaciones_dinero)
     or exists (select 1 from public.historial_asignaciones) then
    raise exception 'La migración requiere tablas financieras vacías; revisar datos existentes antes de continuar';
  end if;
end;
$$;

alter table public.cuentas
  add column saldo_inicial_definido_at timestamptz,
  add column saldo_inicial_monto numeric(14,2),
  add constraint cuentas_saldo_inicial_estado_check check (
    (saldo_inicial_definido_at is null and saldo_inicial_monto is null)
    or (saldo_inicial_definido_at is not null and saldo_inicial_monto >= 0)
  );

alter table public.movimientos
  add column operacion_id uuid,
  add constraint movimientos_detalle_tipo_check check (
    (tipo = 'transferencia' and transferencia_id is not null and direccion_transferencia in ('entrada','salida') and destino_dinero is null and categoria_id is null)
    or (tipo in ('ingreso','gasto') and transferencia_id is null and direccion_transferencia is null and destino_dinero is not null)
    or (tipo = 'saldo_inicial' and transferencia_id is null and direccion_transferencia is null and destino_dinero is null and categoria_id is null)
  );

create unique index movimientos_operacion_unica
  on public.movimientos (usuario_id, operacion_id, coalesce(direccion_transferencia, 'unica'))
  where operacion_id is not null;

alter table public.historial_asignaciones
  drop constraint historial_asignaciones_tipo_check,
  drop constraint historial_asignaciones_monto_check,
  add column operacion_id uuid,
  add column movimiento_id uuid references public.movimientos(id),
  add constraint historial_asignaciones_tipo_check check (tipo in ('asignacion_inicial','redistribucion','ajuste','ingreso','gasto')),
  add constraint historial_asignaciones_monto_check check (
    monto > 0 or (monto = 0 and tipo = 'asignacion_inicial' and destino is null)
  );

create unique index historial_asignaciones_operacion_unica
  on public.historial_asignaciones (usuario_id, operacion_id, coalesce(destino, 'sin_destino'))
  where operacion_id is not null;

-- La app puede leer con RLS, pero no escribir saldos ni historial directamente.
revoke insert, update, delete on public.cuentas, public.movimientos,
  public.asignaciones_dinero, public.historial_asignaciones
  from public, anon, authenticated;

create or replace function public.finanzas_crear_cuenta(
  p_nombre text, p_tipo text, p_codigo text default null
) returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  v_usuario uuid := auth.uid();
  v_id uuid;
begin
  if v_usuario is null then raise exception 'Debes iniciar sesión'; end if;
  if p_nombre is null or length(btrim(p_nombre)) not between 1 and 80 then
    raise exception 'El nombre de la cuenta debe tener entre 1 y 80 caracteres';
  end if;
  if p_tipo is null or p_tipo not in ('efectivo','billetera_digital','banco','otro') then
    raise exception 'Tipo de cuenta no válido';
  end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(v_usuario::text, 0));
  insert into public.cuentas (usuario_id, nombre, tipo, codigo)
  values (v_usuario, btrim(p_nombre), p_tipo, nullif(btrim(p_codigo), ''))
  returning id into v_id;
  return v_id;
end;
$$;

create or replace function public.finanzas_registrar_saldo_inicial(
  p_cuenta_id uuid, p_monto numeric, p_personal numeric, p_negocio numeric,
  p_ahorros numeric, p_operacion_id uuid
) returns void
language plpgsql security definer set search_path = ''
as $$
declare
  v_usuario uuid := auth.uid();
  v_cuenta public.cuentas%rowtype;
  v_movimiento_id uuid;
  v_destino text;
  v_parte numeric;
begin
  if v_usuario is null then raise exception 'Debes iniciar sesión'; end if;
  if p_operacion_id is null then raise exception 'Falta el identificador de operación'; end if;
  if p_monto is null or p_personal is null or p_negocio is null or p_ahorros is null
     or least(p_monto,p_personal,p_negocio,p_ahorros) < 0
     or p_monto <> round(p_monto,2) or p_personal <> round(p_personal,2)
     or p_negocio <> round(p_negocio,2) or p_ahorros <> round(p_ahorros,2)
     or p_personal + p_negocio + p_ahorros <> p_monto then
    raise exception 'El saldo inicial debe ser no negativo y coincidir con la distribución';
  end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(v_usuario::text, 0));
  select * into v_cuenta from public.cuentas
    where id = p_cuenta_id and usuario_id = v_usuario and activa for update;
  if not found then raise exception 'Cuenta no encontrada o inactiva'; end if;
  if v_cuenta.saldo_inicial_definido_at is not null then
    raise exception 'El saldo inicial ya fue registrado';
  end if;
  update public.cuentas set saldo_inicial_definido_at = now(), saldo_inicial_monto = p_monto,
    fecha_actualizacion = now() where id = p_cuenta_id;
  if p_monto > 0 then
    insert into public.movimientos (usuario_id, cuenta_id, tipo, monto, descripcion, operacion_id)
    values (v_usuario, p_cuenta_id, 'saldo_inicial', p_monto, 'Saldo inicial', p_operacion_id)
    returning id into v_movimiento_id;
  end if;
  for v_destino, v_parte in
    select destino, parte from (values ('personal',p_personal),('negocio',p_negocio),('ahorros',p_ahorros)) as d(destino,parte)
  loop
    if v_parte > 0 then
      insert into public.asignaciones_dinero (usuario_id,destino,monto)
      values (v_usuario,v_destino,v_parte)
      on conflict (usuario_id,destino) do update
      set monto = public.asignaciones_dinero.monto + excluded.monto, fecha_actualizacion = now();
      insert into public.historial_asignaciones
        (usuario_id,destino,monto,tipo,descripcion,operacion_id,movimiento_id)
      values (v_usuario,v_destino,v_parte,'asignacion_inicial','Saldo inicial',p_operacion_id,v_movimiento_id);
    end if;
  end loop;
  if p_monto = 0 then
    insert into public.historial_asignaciones
      (usuario_id,monto,tipo,descripcion,operacion_id)
    values (v_usuario,0,'asignacion_inicial','Saldo inicial cero',p_operacion_id);
  end if;
end;
$$;

create or replace function public.finanzas_registrar_movimiento(
  p_cuenta_id uuid, p_tipo text, p_monto numeric, p_destino text,
  p_descripcion text, p_categoria_id uuid, p_operacion_id uuid
) returns void
language plpgsql security definer set search_path = ''
as $$
declare
  v_usuario uuid := auth.uid();
  v_cuenta public.cuentas%rowtype;
  v_balance numeric;
  v_movimiento_id uuid;
begin
  if v_usuario is null then raise exception 'Debes iniciar sesión'; end if;
  if p_operacion_id is null then raise exception 'Falta el identificador de operación'; end if;
  if p_tipo is null or p_tipo not in ('ingreso','gasto') then raise exception 'Tipo de movimiento no válido'; end if;
  if p_destino is null or p_destino not in ('personal','negocio','ahorros') then raise exception 'Destino no válido'; end if;
  if p_monto is null or p_monto <= 0 or p_monto <> round(p_monto,2) then raise exception 'El monto debe ser positivo y tener hasta dos decimales'; end if;
  if p_descripcion is not null and length(p_descripcion) > 300 then raise exception 'Descripción demasiado larga'; end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(v_usuario::text, 0));
  select * into v_cuenta from public.cuentas
    where id = p_cuenta_id and usuario_id = v_usuario and activa for update;
  if not found then raise exception 'Cuenta no encontrada o inactiva'; end if;
  if v_cuenta.saldo_inicial_definido_at is null then raise exception 'Primero registra el saldo inicial de la cuenta'; end if;
  if p_categoria_id is not null and not exists (
    select 1 from public.categorias where id = p_categoria_id and usuario_id = v_usuario
      and tipo = p_tipo and activa
  ) then raise exception 'Categoría no válida para este movimiento'; end if;
  if p_tipo = 'gasto' then
    select coalesce(sum(case
      when tipo in ('saldo_inicial','ingreso') or (tipo = 'transferencia' and direccion_transferencia = 'entrada') then monto
      else -monto end),0) into v_balance
    from public.movimientos where cuenta_id = p_cuenta_id and usuario_id = v_usuario;
    if v_balance < p_monto then raise exception 'Saldo insuficiente en la cuenta'; end if;
    update public.asignaciones_dinero set monto = monto - p_monto, fecha_actualizacion = now()
      where usuario_id = v_usuario and destino = p_destino and monto >= p_monto;
    if not found then raise exception 'Saldo insuficiente en el destino'; end if;
  end if;
  insert into public.movimientos
    (usuario_id,cuenta_id,categoria_id,tipo,monto,descripcion,destino_dinero,operacion_id)
  values (v_usuario,p_cuenta_id,p_categoria_id,p_tipo,p_monto,nullif(btrim(p_descripcion),''),p_destino,p_operacion_id)
  returning id into v_movimiento_id;
  if p_tipo = 'ingreso' then
    insert into public.asignaciones_dinero (usuario_id,destino,monto)
    values (v_usuario,p_destino,p_monto)
    on conflict (usuario_id,destino) do update
    set monto = public.asignaciones_dinero.monto + excluded.monto, fecha_actualizacion = now();
  end if;
  insert into public.historial_asignaciones
    (usuario_id,origen,destino,monto,tipo,descripcion,operacion_id,movimiento_id)
  values (v_usuario,case when p_tipo='gasto' then p_destino else null end,
    case when p_tipo='ingreso' then p_destino else null end,
    p_monto,p_tipo,nullif(btrim(p_descripcion),''),p_operacion_id,v_movimiento_id);
end;
$$;

create or replace function public.finanzas_transferir(
  p_origen_id uuid, p_destino_id uuid, p_monto numeric,
  p_descripcion text, p_operacion_id uuid
) returns void
language plpgsql security definer set search_path = ''
as $$
declare
  v_usuario uuid := auth.uid();
  v_cuentas integer;
  v_balance numeric;
begin
  if v_usuario is null then raise exception 'Debes iniciar sesión'; end if;
  if p_operacion_id is null then raise exception 'Falta el identificador de operación'; end if;
  if p_origen_id is null or p_destino_id is null or p_origen_id = p_destino_id then raise exception 'Elige dos cuentas distintas'; end if;
  if p_monto is null or p_monto <= 0 or p_monto <> round(p_monto,2) then raise exception 'El monto debe ser positivo y tener hasta dos decimales'; end if;
  if p_descripcion is not null and length(p_descripcion) > 300 then raise exception 'Descripción demasiado larga'; end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(v_usuario::text, 0));
  select count(*) into v_cuentas from public.cuentas
    where id in (p_origen_id,p_destino_id) and usuario_id = v_usuario
      and activa and saldo_inicial_definido_at is not null;
  if v_cuentas <> 2 then raise exception 'Ambas cuentas deben ser propias, activas y tener saldo inicial registrado'; end if;
  select coalesce(sum(case
    when tipo in ('saldo_inicial','ingreso') or (tipo = 'transferencia' and direccion_transferencia = 'entrada') then monto
    else -monto end),0) into v_balance
  from public.movimientos where cuenta_id = p_origen_id and usuario_id = v_usuario;
  if v_balance < p_monto then raise exception 'Saldo insuficiente en la cuenta de origen'; end if;
  insert into public.movimientos
    (usuario_id,cuenta_id,tipo,monto,descripcion,transferencia_id,direccion_transferencia,operacion_id)
  values
    (v_usuario,p_origen_id,'transferencia',p_monto,nullif(btrim(p_descripcion),''),p_operacion_id,'salida',p_operacion_id),
    (v_usuario,p_destino_id,'transferencia',p_monto,nullif(btrim(p_descripcion),''),p_operacion_id,'entrada',p_operacion_id);
end;
$$;

create or replace function public.finanzas_redistribuir(
  p_origen text, p_destino text, p_monto numeric,
  p_descripcion text, p_operacion_id uuid
) returns void
language plpgsql security definer set search_path = ''
as $$
declare
  v_usuario uuid := auth.uid();
begin
  if v_usuario is null then raise exception 'Debes iniciar sesión'; end if;
  if p_operacion_id is null then raise exception 'Falta el identificador de operación'; end if;
  if p_origen is null or p_destino is null
     or p_origen not in ('personal','negocio','ahorros')
     or p_destino not in ('personal','negocio','ahorros') or p_origen = p_destino then
    raise exception 'Elige dos destinos distintos';
  end if;
  if p_monto is null or p_monto <= 0 or p_monto <> round(p_monto,2) then raise exception 'El monto debe ser positivo y tener hasta dos decimales'; end if;
  if p_descripcion is not null and length(p_descripcion) > 300 then raise exception 'Descripción demasiado larga'; end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(v_usuario::text, 0));
  update public.asignaciones_dinero set monto = monto - p_monto, fecha_actualizacion = now()
    where usuario_id = v_usuario and destino = p_origen and monto >= p_monto;
  if not found then raise exception 'Saldo insuficiente en el destino de origen'; end if;
  insert into public.asignaciones_dinero (usuario_id,destino,monto)
  values (v_usuario,p_destino,p_monto)
  on conflict (usuario_id,destino) do update
  set monto = public.asignaciones_dinero.monto + excluded.monto, fecha_actualizacion = now();
  insert into public.historial_asignaciones
    (usuario_id,origen,destino,monto,tipo,descripcion,operacion_id)
  values (v_usuario,p_origen,p_destino,p_monto,'redistribucion',nullif(btrim(p_descripcion),''),p_operacion_id);
end;
$$;

-- Solo las funciones validadas reciben permiso de escritura desde React.
revoke all on function public.finanzas_crear_cuenta(text,text,text) from public, anon, authenticated;
revoke all on function public.finanzas_registrar_saldo_inicial(uuid,numeric,numeric,numeric,numeric,uuid) from public, anon, authenticated;
revoke all on function public.finanzas_registrar_movimiento(uuid,text,numeric,text,text,uuid,uuid) from public, anon, authenticated;
revoke all on function public.finanzas_transferir(uuid,uuid,numeric,text,uuid) from public, anon, authenticated;
revoke all on function public.finanzas_redistribuir(text,text,numeric,text,uuid) from public, anon, authenticated;
grant execute on function public.finanzas_crear_cuenta(text,text,text) to authenticated;
grant execute on function public.finanzas_registrar_saldo_inicial(uuid,numeric,numeric,numeric,numeric,uuid) to authenticated;
grant execute on function public.finanzas_registrar_movimiento(uuid,text,numeric,text,text,uuid,uuid) to authenticated;
grant execute on function public.finanzas_transferir(uuid,uuid,numeric,text,uuid) to authenticated;
grant execute on function public.finanzas_redistribuir(text,text,numeric,text,uuid) to authenticated;

create view public.finanzas_saldos_cuentas with (security_invoker = true) as
select c.id, c.usuario_id, c.nombre, c.tipo, c.codigo, c.activa,
  c.saldo_inicial_definido_at, c.saldo_inicial_monto,
  coalesce(sum(case
    when m.tipo in ('saldo_inicial','ingreso') or (m.tipo='transferencia' and m.direccion_transferencia='entrada') then m.monto
    when m.id is null then 0
    else -m.monto end),0)::numeric(14,2) as saldo
from public.cuentas c
left join public.movimientos m on m.cuenta_id=c.id and m.usuario_id=c.usuario_id
group by c.id;
revoke all on public.finanzas_saldos_cuentas from public, anon, authenticated;
grant select on public.finanzas_saldos_cuentas to authenticated;
