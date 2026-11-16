-- Incremental sobre 20261104191448_finanzas_operaciones_seguras.sql.
-- Añade: gestión de categorías, fecha elegible en movimientos y transferencias,
-- y anulación auditada de movimientos (sin borrar filas).
-- No borra datos. Requiere revisión y aprobación explícita antes de aplicarse en remoto.
set lock_timeout = '5s';

-- 1. Lectura explícita para el rol autenticado (RLS sigue limitando a filas propias).
grant select on public.cuentas, public.categorias, public.movimientos,
  public.asignaciones_dinero, public.historial_asignaciones to authenticated;

-- Las categorías pasan a escribirse solo mediante funciones validadas.
revoke insert, update, delete on public.categorias from public, anon, authenticated;

-- 2. Anulación: el movimiento se conserva y se marca como anulado.
alter table public.movimientos
  add column anulado_at timestamptz,
  add column anulado_motivo text,
  add constraint movimientos_anulacion_check check (
    (anulado_at is null and anulado_motivo is null)
    or (anulado_at is not null and (anulado_motivo is null or length(anulado_motivo) <= 300))
  );

alter table public.historial_asignaciones
  drop constraint historial_asignaciones_tipo_check,
  add constraint historial_asignaciones_tipo_check check (
    tipo in ('asignacion_inicial','redistribucion','ajuste','ingreso','gasto','anulacion')
  );

-- Saldo físico de una cuenta ignorando movimientos anulados.
create or replace function public.finanzas_saldo_cuenta(p_cuenta_id uuid, p_usuario uuid)
returns numeric
language sql stable security definer set search_path = ''
as $$
  select coalesce(sum(case
    when tipo in ('saldo_inicial','ingreso') or (tipo = 'transferencia' and direccion_transferencia = 'entrada') then monto
    else -monto end),0)
  from public.movimientos
  where cuenta_id = p_cuenta_id and usuario_id = p_usuario and anulado_at is null;
$$;
revoke all on function public.finanzas_saldo_cuenta(uuid,uuid) from public, anon, authenticated;

-- Convierte una fecha elegida por el usuario (hora de Lima) en marca de tiempo.
create or replace function public.finanzas_fecha_operacion(p_fecha date)
returns timestamptz
language plpgsql stable security definer set search_path = ''
as $$
declare
  v_hoy date := (now() at time zone 'America/Lima')::date;
begin
  if p_fecha is null or p_fecha = v_hoy then return now(); end if;
  if p_fecha > v_hoy then raise exception 'La fecha no puede estar en el futuro'; end if;
  if p_fecha < date '2020-01-01' then raise exception 'La fecha es demasiado antigua'; end if;
  return (p_fecha::timestamp + time '12:00') at time zone 'America/Lima';
end;
$$;
revoke all on function public.finanzas_fecha_operacion(date) from public, anon, authenticated;

-- 3. Vista de saldos recalculada sin movimientos anulados.
create or replace view public.finanzas_saldos_cuentas with (security_invoker = true) as
select c.id, c.usuario_id, c.nombre, c.tipo, c.codigo, c.activa,
  c.saldo_inicial_definido_at, c.saldo_inicial_monto,
  coalesce(sum(case
    when m.tipo in ('saldo_inicial','ingreso') or (m.tipo='transferencia' and m.direccion_transferencia='entrada') then m.monto
    when m.id is null then 0
    else -m.monto end),0)::numeric(14,2) as saldo
from public.cuentas c
left join public.movimientos m
  on m.cuenta_id=c.id and m.usuario_id=c.usuario_id and m.anulado_at is null
group by c.id;

-- 4. Ingreso / gasto con fecha opcional.
drop function public.finanzas_registrar_movimiento(uuid,text,numeric,text,text,uuid,uuid);
create function public.finanzas_registrar_movimiento(
  p_cuenta_id uuid, p_tipo text, p_monto numeric, p_destino text,
  p_descripcion text, p_categoria_id uuid, p_operacion_id uuid,
  p_fecha date default null
) returns void
language plpgsql security definer set search_path = ''
as $$
declare
  v_usuario uuid := auth.uid();
  v_cuenta public.cuentas%rowtype;
  v_movimiento_id uuid;
  v_fecha timestamptz;
begin
  if v_usuario is null then raise exception 'Debes iniciar sesión'; end if;
  if p_operacion_id is null then raise exception 'Falta el identificador de operación'; end if;
  if p_tipo is null or p_tipo not in ('ingreso','gasto') then raise exception 'Tipo de movimiento no válido'; end if;
  if p_destino is null or p_destino not in ('personal','negocio','ahorros') then raise exception 'Destino no válido'; end if;
  if p_monto is null or p_monto <= 0 or p_monto <> round(p_monto,2) then raise exception 'El monto debe ser positivo y tener hasta dos decimales'; end if;
  if p_descripcion is not null and length(p_descripcion) > 300 then raise exception 'Descripción demasiado larga'; end if;
  v_fecha := public.finanzas_fecha_operacion(p_fecha);

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
    if public.finanzas_saldo_cuenta(p_cuenta_id, v_usuario) < p_monto then
      raise exception 'Saldo insuficiente en la cuenta';
    end if;
    update public.asignaciones_dinero set monto = monto - p_monto, fecha_actualizacion = now()
      where usuario_id = v_usuario and destino = p_destino and monto >= p_monto;
    if not found then raise exception 'Saldo insuficiente en el destino'; end if;
  end if;

  insert into public.movimientos
    (usuario_id,cuenta_id,categoria_id,tipo,monto,descripcion,destino_dinero,operacion_id,fecha_movimiento)
  values (v_usuario,p_cuenta_id,p_categoria_id,p_tipo,p_monto,nullif(btrim(p_descripcion),''),p_destino,p_operacion_id,v_fecha)
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

-- 5. Transferencia con fecha opcional.
drop function public.finanzas_transferir(uuid,uuid,numeric,text,uuid);
create function public.finanzas_transferir(
  p_origen_id uuid, p_destino_id uuid, p_monto numeric,
  p_descripcion text, p_operacion_id uuid, p_fecha date default null
) returns void
language plpgsql security definer set search_path = ''
as $$
declare
  v_usuario uuid := auth.uid();
  v_cuentas integer;
  v_fecha timestamptz;
begin
  if v_usuario is null then raise exception 'Debes iniciar sesión'; end if;
  if p_operacion_id is null then raise exception 'Falta el identificador de operación'; end if;
  if p_origen_id is null or p_destino_id is null or p_origen_id = p_destino_id then raise exception 'Elige dos cuentas distintas'; end if;
  if p_monto is null or p_monto <= 0 or p_monto <> round(p_monto,2) then raise exception 'El monto debe ser positivo y tener hasta dos decimales'; end if;
  if p_descripcion is not null and length(p_descripcion) > 300 then raise exception 'Descripción demasiado larga'; end if;
  v_fecha := public.finanzas_fecha_operacion(p_fecha);

  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(v_usuario::text, 0));

  select count(*) into v_cuentas from public.cuentas
    where id in (p_origen_id,p_destino_id) and usuario_id = v_usuario
      and activa and saldo_inicial_definido_at is not null;
  if v_cuentas <> 2 then raise exception 'Ambas cuentas deben ser propias, activas y tener saldo inicial registrado'; end if;

  if public.finanzas_saldo_cuenta(p_origen_id, v_usuario) < p_monto then
    raise exception 'Saldo insuficiente en la cuenta de origen';
  end if;

  insert into public.movimientos
    (usuario_id,cuenta_id,tipo,monto,descripcion,transferencia_id,direccion_transferencia,operacion_id,fecha_movimiento)
  values
    (v_usuario,p_origen_id,'transferencia',p_monto,nullif(btrim(p_descripcion),''),p_operacion_id,'salida',p_operacion_id,v_fecha),
    (v_usuario,p_destino_id,'transferencia',p_monto,nullif(btrim(p_descripcion),''),p_operacion_id,'entrada',p_operacion_id,v_fecha);
end;
$$;

-- 6. Anular un ingreso, gasto o transferencia (ambos lados).
create function public.finanzas_anular_movimiento(
  p_movimiento_id uuid, p_motivo text, p_operacion_id uuid
) returns void
language plpgsql security definer set search_path = ''
as $$
declare
  v_usuario uuid := auth.uid();
  v_mov public.movimientos%rowtype;
  v_entrada public.movimientos%rowtype;
  v_motivo text := nullif(btrim(p_motivo),'');
begin
  if v_usuario is null then raise exception 'Debes iniciar sesión'; end if;
  if p_operacion_id is null then raise exception 'Falta el identificador de operación'; end if;
  if v_motivo is not null and length(v_motivo) > 300 then raise exception 'Motivo demasiado largo'; end if;

  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(v_usuario::text, 0));

  select * into v_mov from public.movimientos
    where id = p_movimiento_id and usuario_id = v_usuario for update;
  if not found then raise exception 'Movimiento no encontrado'; end if;
  if v_mov.anulado_at is not null then raise exception 'Esta operación ya fue anulada'; end if;
  if v_mov.tipo = 'saldo_inicial' then raise exception 'El saldo inicial no se puede anular'; end if;

  if v_mov.tipo = 'ingreso' then
    -- Quitar el dinero que había entrado: la cuenta y el destino deben tenerlo todavía.
    if public.finanzas_saldo_cuenta(v_mov.cuenta_id, v_usuario) < v_mov.monto then
      raise exception 'Saldo insuficiente en la cuenta para anular este ingreso';
    end if;
    update public.asignaciones_dinero set monto = monto - v_mov.monto, fecha_actualizacion = now()
      where usuario_id = v_usuario and destino = v_mov.destino_dinero and monto >= v_mov.monto;
    if not found then raise exception 'Saldo insuficiente en el destino para anular este ingreso'; end if;
    update public.movimientos set anulado_at = now(), anulado_motivo = v_motivo where id = v_mov.id;
    insert into public.historial_asignaciones
      (usuario_id,origen,destino,monto,tipo,descripcion,operacion_id,movimiento_id)
    values (v_usuario,v_mov.destino_dinero,null,v_mov.monto,'anulacion',
      coalesce(v_motivo,'Anulación de ingreso'),p_operacion_id,v_mov.id);

  elsif v_mov.tipo = 'gasto' then
    -- Devolver el dinero a la cuenta y al destino.
    insert into public.asignaciones_dinero (usuario_id,destino,monto)
    values (v_usuario,v_mov.destino_dinero,v_mov.monto)
    on conflict (usuario_id,destino) do update
    set monto = public.asignaciones_dinero.monto + excluded.monto, fecha_actualizacion = now();
    update public.movimientos set anulado_at = now(), anulado_motivo = v_motivo where id = v_mov.id;
    insert into public.historial_asignaciones
      (usuario_id,origen,destino,monto,tipo,descripcion,operacion_id,movimiento_id)
    values (v_usuario,null,v_mov.destino_dinero,v_mov.monto,'anulacion',
      coalesce(v_motivo,'Anulación de gasto'),p_operacion_id,v_mov.id);

  else
    -- Transferencia: se anulan los dos lados; la cuenta que recibió debe tener el dinero.
    select * into v_entrada from public.movimientos
      where transferencia_id = v_mov.transferencia_id and usuario_id = v_usuario
        and direccion_transferencia = 'entrada' for update;
    if not found then raise exception 'Transferencia incompleta'; end if;
    if public.finanzas_saldo_cuenta(v_entrada.cuenta_id, v_usuario) < v_entrada.monto then
      raise exception 'Saldo insuficiente en la cuenta de destino para anular la transferencia';
    end if;
    update public.movimientos set anulado_at = now(), anulado_motivo = v_motivo
      where transferencia_id = v_mov.transferencia_id and usuario_id = v_usuario;
    insert into public.historial_asignaciones
      (usuario_id,origen,destino,monto,tipo,descripcion,operacion_id,movimiento_id)
    values (v_usuario,null,null,v_mov.monto,'anulacion',
      coalesce(v_motivo,'Anulación de transferencia'),p_operacion_id,v_mov.id);
  end if;
end;
$$;

-- 7. Categorías.
create function public.finanzas_crear_categoria(p_nombre text, p_tipo text)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  v_usuario uuid := auth.uid();
  v_nombre text := btrim(p_nombre);
  v_id uuid;
  v_activa boolean;
begin
  if v_usuario is null then raise exception 'Debes iniciar sesión'; end if;
  if v_nombre is null or length(v_nombre) not between 1 and 60 then
    raise exception 'El nombre de la categoría debe tener entre 1 y 60 caracteres';
  end if;
  if p_tipo is null or p_tipo not in ('ingreso','gasto') then raise exception 'Tipo de categoría no válido'; end if;

  select id, activa into v_id, v_activa from public.categorias
    where usuario_id = v_usuario and tipo = p_tipo and lower(nombre) = lower(v_nombre);
  if found then
    if v_activa then raise exception 'La categoría ya existe'; end if;
    update public.categorias set activa = true where id = v_id;
    return v_id;
  end if;

  insert into public.categorias (usuario_id, nombre, tipo)
  values (v_usuario, v_nombre, p_tipo) returning id into v_id;
  return v_id;
end;
$$;

-- Desactivar conserva la categoría en los movimientos antiguos.
create function public.finanzas_desactivar_categoria(p_categoria_id uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  v_usuario uuid := auth.uid();
begin
  if v_usuario is null then raise exception 'Debes iniciar sesión'; end if;
  update public.categorias set activa = false
    where id = p_categoria_id and usuario_id = v_usuario and activa;
  if not found then raise exception 'Categoría no encontrada'; end if;
end;
$$;

-- Crea las categorías sugeridas que falten (idempotente).
create function public.finanzas_crear_categorias_sugeridas()
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  v_usuario uuid := auth.uid();
begin
  if v_usuario is null then raise exception 'Debes iniciar sesión'; end if;
  insert into public.categorias (usuario_id, nombre, tipo)
  select v_usuario, s.nombre, s.tipo
  from (values
    ('Trabajo','ingreso'), ('Padres','ingreso'), ('Ventas','ingreso'), ('Otros ingresos','ingreso'),
    ('Comida','gasto'), ('Transporte','gasto'), ('Estudios','gasto'),
    ('Personal','gasto'), ('Otros gastos','gasto')
  ) as s(nombre, tipo)
  where not exists (
    select 1 from public.categorias c
    where c.usuario_id = v_usuario and c.tipo = s.tipo and lower(c.nombre) = lower(s.nombre)
  );
end;
$$;

-- 8. Permisos: solo el rol autenticado puede invocar las funciones públicas.
revoke all on function public.finanzas_registrar_movimiento(uuid,text,numeric,text,text,uuid,uuid,date) from public, anon, authenticated;
revoke all on function public.finanzas_transferir(uuid,uuid,numeric,text,uuid,date) from public, anon, authenticated;
revoke all on function public.finanzas_anular_movimiento(uuid,text,uuid) from public, anon, authenticated;
revoke all on function public.finanzas_crear_categoria(text,text) from public, anon, authenticated;
revoke all on function public.finanzas_desactivar_categoria(uuid) from public, anon, authenticated;
revoke all on function public.finanzas_crear_categorias_sugeridas() from public, anon, authenticated;
grant execute on function public.finanzas_registrar_movimiento(uuid,text,numeric,text,text,uuid,uuid,date) to authenticated;
grant execute on function public.finanzas_transferir(uuid,uuid,numeric,text,uuid,date) to authenticated;
grant execute on function public.finanzas_anular_movimiento(uuid,text,uuid) to authenticated;
grant execute on function public.finanzas_crear_categoria(text,text) to authenticated;
grant execute on function public.finanzas_desactivar_categoria(uuid) to authenticated;
grant execute on function public.finanzas_crear_categorias_sugeridas() to authenticated;

revoke all on public.finanzas_saldos_cuentas from public, anon, authenticated;
grant select on public.finanzas_saldos_cuentas to authenticated;
