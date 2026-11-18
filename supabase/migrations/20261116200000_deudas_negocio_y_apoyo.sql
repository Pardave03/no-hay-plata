-- Incremental sobre las dos migraciones de Finanzas.
-- Añade: Deudas (con pagos parciales), Negocio (productos, compras, ventas, stock),
-- Pedidos, metas de ahorro, hojas de notas, gestión de cuentas y vistas de resumen.
-- Todo movimiento de dinero pasa por las funciones de Finanzas: no se duplican movimientos.
-- No borra datos. Requiere revisión y aprobación antes de aplicarse en remoto.
set lock_timeout = '5s';

-- ---------------------------------------------------------------------------
-- 1. Finanzas: origen del movimiento y funciones internas reutilizables
-- ---------------------------------------------------------------------------
alter table public.movimientos
  add column origen text not null default 'manual',
  add constraint movimientos_origen_check check (origen in ('manual','deuda','compra','venta'));

-- Función interna: registra un ingreso o gasto y devuelve su id. No se expone a la app.
create function public.finanzas__movimiento(
  p_cuenta_id uuid, p_tipo text, p_monto numeric, p_destino text,
  p_descripcion text, p_categoria_id uuid, p_operacion_id uuid,
  p_fecha date, p_origen text
) returns uuid
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
    if not found then raise exception 'Saldo insuficiente en el destino %', p_destino; end if;
  end if;

  insert into public.movimientos
    (usuario_id,cuenta_id,categoria_id,tipo,monto,descripcion,destino_dinero,operacion_id,fecha_movimiento,origen)
  values (v_usuario,p_cuenta_id,p_categoria_id,p_tipo,p_monto,nullif(btrim(p_descripcion),''),p_destino,p_operacion_id,v_fecha,p_origen)
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
  return v_movimiento_id;
end;
$$;

-- La función pública conserva su firma: registra movimientos manuales.
create or replace function public.finanzas_registrar_movimiento(
  p_cuenta_id uuid, p_tipo text, p_monto numeric, p_destino text,
  p_descripcion text, p_categoria_id uuid, p_operacion_id uuid,
  p_fecha date default null
) returns void
language plpgsql security definer set search_path = ''
as $$
begin
  perform public.finanzas__movimiento(p_cuenta_id,p_tipo,p_monto,p_destino,p_descripcion,
    p_categoria_id,p_operacion_id,p_fecha,'manual');
end;
$$;

-- Función interna: anula cualquier movimiento (la lógica que antes tenía la pública).
create function public.finanzas__anular(
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
    if public.finanzas_saldo_cuenta(v_mov.cuenta_id, v_usuario) < v_mov.monto then
      raise exception 'Saldo insuficiente en la cuenta para anular este ingreso: ese dinero ya se usó';
    end if;
    update public.asignaciones_dinero set monto = monto - v_mov.monto, fecha_actualizacion = now()
      where usuario_id = v_usuario and destino = v_mov.destino_dinero and monto >= v_mov.monto;
    if not found then raise exception 'Saldo insuficiente en el destino para anular este ingreso: ese dinero ya se usó'; end if;
    update public.movimientos set anulado_at = now(), anulado_motivo = v_motivo where id = v_mov.id;
    insert into public.historial_asignaciones
      (usuario_id,origen,destino,monto,tipo,descripcion,operacion_id,movimiento_id)
    values (v_usuario,v_mov.destino_dinero,null,v_mov.monto,'anulacion',
      coalesce(v_motivo,'Anulación de ingreso'),p_operacion_id,v_mov.id);

  elsif v_mov.tipo = 'gasto' then
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

-- La función pública solo anula movimientos manuales: los de ventas, compras y deudas
-- se anulan desde su módulo para que stock y saldos pendientes no queden descuadrados.
create or replace function public.finanzas_anular_movimiento(
  p_movimiento_id uuid, p_motivo text, p_operacion_id uuid
) returns void
language plpgsql security definer set search_path = ''
as $$
declare
  v_origen text;
begin
  select origen into v_origen from public.movimientos
    where id = p_movimiento_id and usuario_id = auth.uid();
  if not found then raise exception 'Movimiento no encontrado'; end if;
  if v_origen <> 'manual' then
    raise exception 'Este movimiento viene de una venta, compra o deuda: anúlalo desde ese módulo';
  end if;
  perform public.finanzas__anular(p_movimiento_id, p_motivo, p_operacion_id);
end;
$$;

-- Renombrar o desactivar una cuenta (solo se desactiva con saldo cero).
create function public.finanzas_actualizar_cuenta(
  p_cuenta_id uuid, p_nombre text, p_activa boolean
) returns void
language plpgsql security definer set search_path = ''
as $$
declare
  v_usuario uuid := auth.uid();
begin
  if v_usuario is null then raise exception 'Debes iniciar sesión'; end if;
  if p_nombre is null or length(btrim(p_nombre)) not between 1 and 80 then
    raise exception 'El nombre de la cuenta debe tener entre 1 y 80 caracteres';
  end if;
  if p_activa is null then raise exception 'Indica si la cuenta sigue activa'; end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(v_usuario::text, 0));
  if not p_activa and public.finanzas_saldo_cuenta(p_cuenta_id, v_usuario) <> 0 then
    raise exception 'Solo puedes desactivar una cuenta con saldo cero: transfiere su dinero primero';
  end if;
  update public.cuentas set nombre = btrim(p_nombre), activa = p_activa, fecha_actualizacion = now()
    where id = p_cuenta_id and usuario_id = v_usuario;
  if not found then raise exception 'Cuenta no encontrada'; end if;
end;
$$;

-- Totales por mes (hora de Lima) para Inicio y Reportes. Excluye anulados y transferencias.
create view public.finanzas_resumen_mensual with (security_invoker = true) as
select usuario_id,
  to_char(fecha_movimiento at time zone 'America/Lima', 'YYYY-MM') as mes,
  tipo, origen, destino_dinero, categoria_id,
  sum(monto)::numeric(14,2) as total, count(*)::integer as cantidad
from public.movimientos
where anulado_at is null and tipo in ('ingreso','gasto')
group by usuario_id, 2, tipo, origen, destino_dinero, categoria_id;

-- ---------------------------------------------------------------------------
-- 2. Deudas
-- ---------------------------------------------------------------------------
create table public.deudas (
  id uuid primary key default gen_random_uuid(),
  usuario_id uuid not null references auth.users(id) on delete cascade,
  tipo text not null check (tipo in ('por_cobrar','por_pagar')),
  persona text not null check (length(btrim(persona)) between 1 and 80),
  concepto text check (concepto is null or length(concepto) <= 300),
  monto_total numeric(14,2) not null check (monto_total > 0),
  destino_dinero text not null default 'personal' check (destino_dinero in ('personal','negocio','ahorros')),
  categoria_id uuid references public.categorias(id),
  fecha_origen date not null,
  fecha_vencimiento date,
  origen text not null default 'manual' check (origen in ('manual','venta')),
  movimiento_inicial_id uuid references public.movimientos(id),
  operacion_id uuid not null,
  anulada_at timestamptz,
  fecha_creacion timestamptz not null default now(),
  constraint deudas_operacion_unica unique (usuario_id, operacion_id)
);
create index deudas_usuario_idx on public.deudas (usuario_id, fecha_creacion desc);

create table public.deuda_pagos (
  id uuid primary key default gen_random_uuid(),
  usuario_id uuid not null references auth.users(id) on delete cascade,
  deuda_id uuid not null references public.deudas(id) on delete cascade,
  monto numeric(14,2) not null check (monto > 0),
  fecha date not null,
  movimiento_id uuid not null references public.movimientos(id),
  operacion_id uuid not null,
  anulado_at timestamptz,
  fecha_creacion timestamptz not null default now(),
  constraint deuda_pagos_operacion_unica unique (usuario_id, operacion_id)
);
create index deuda_pagos_deuda_idx on public.deuda_pagos (deuda_id);

-- Saldo pendiente y estado calculados: los pagos parciales nunca borran la deuda original.
create view public.deudas_resumen with (security_invoker = true) as
select d.*,
  coalesce(p.pagado, 0)::numeric(14,2) as pagado,
  (d.monto_total - coalesce(p.pagado, 0))::numeric(14,2) as saldo,
  case
    when d.anulada_at is not null then 'anulada'
    when coalesce(p.pagado, 0) >= d.monto_total then 'pagada'
    when coalesce(p.pagado, 0) > 0 then 'parcial'
    else 'pendiente'
  end as estado
from public.deudas d
left join (
  select deuda_id, sum(monto) as pagado from public.deuda_pagos
  where anulado_at is null group by deuda_id
) p on p.deuda_id = d.id;

-- Crea una deuda. Si se indica una cuenta, el dinero se mueve ahora (un préstamo):
-- por cobrar = presté dinero (sale); por pagar = me prestaron (entra).
-- Sin cuenta no se mueve dinero (por ejemplo, un pago pendiente del trabajo).
create function public.deudas_crear(
  p_tipo text, p_persona text, p_concepto text, p_monto numeric, p_destino text,
  p_categoria_id uuid, p_fecha_vencimiento date, p_cuenta_id uuid, p_operacion_id uuid
) returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  v_usuario uuid := auth.uid();
  v_hoy date := (now() at time zone 'America/Lima')::date;
  v_movimiento_id uuid;
  v_id uuid;
begin
  if v_usuario is null then raise exception 'Debes iniciar sesión'; end if;
  if p_operacion_id is null then raise exception 'Falta el identificador de operación'; end if;
  if p_tipo is null or p_tipo not in ('por_cobrar','por_pagar') then raise exception 'Tipo de deuda no válido'; end if;
  if p_persona is null or length(btrim(p_persona)) not between 1 and 80 then
    raise exception 'Escribe el nombre de la persona (hasta 80 caracteres)';
  end if;
  if p_concepto is not null and length(p_concepto) > 300 then raise exception 'Concepto demasiado largo'; end if;
  if p_monto is null or p_monto <= 0 or p_monto <> round(p_monto,2) then raise exception 'El monto debe ser positivo y tener hasta dos decimales'; end if;
  if p_destino is null or p_destino not in ('personal','negocio','ahorros') then raise exception 'Destino no válido'; end if;
  if p_categoria_id is not null and not exists (
    select 1 from public.categorias where id = p_categoria_id and usuario_id = v_usuario and activa
      and tipo = case when p_tipo = 'por_cobrar' then 'ingreso' else 'gasto' end
  ) then raise exception 'Categoría no válida para esta deuda'; end if;

  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(v_usuario::text, 0));

  if p_cuenta_id is not null then
    v_movimiento_id := public.finanzas__movimiento(
      p_cuenta_id, case when p_tipo = 'por_cobrar' then 'gasto' else 'ingreso' end,
      p_monto, p_destino,
      left(case when p_tipo = 'por_cobrar' then 'Préstamo a ' else 'Préstamo de ' end || btrim(p_persona), 300),
      null, p_operacion_id, null, 'deuda');
  end if;

  insert into public.deudas (usuario_id,tipo,persona,concepto,monto_total,destino_dinero,categoria_id,
    fecha_origen,fecha_vencimiento,movimiento_inicial_id,operacion_id)
  values (v_usuario,p_tipo,btrim(p_persona),nullif(btrim(p_concepto),''),p_monto,p_destino,p_categoria_id,
    v_hoy,p_fecha_vencimiento,v_movimiento_id,p_operacion_id)
  returning id into v_id;
  return v_id;
end;
$$;

-- Pago parcial o total: por cobrar genera un ingreso; por pagar, un gasto.
create function public.deudas_registrar_pago(
  p_deuda_id uuid, p_monto numeric, p_cuenta_id uuid, p_fecha date, p_operacion_id uuid
) returns void
language plpgsql security definer set search_path = ''
as $$
declare
  v_usuario uuid := auth.uid();
  v_deuda public.deudas%rowtype;
  v_pagado numeric;
  v_categoria uuid;
  v_movimiento_id uuid;
begin
  if v_usuario is null then raise exception 'Debes iniciar sesión'; end if;
  if p_operacion_id is null then raise exception 'Falta el identificador de operación'; end if;
  if p_monto is null or p_monto <= 0 or p_monto <> round(p_monto,2) then raise exception 'El monto debe ser positivo y tener hasta dos decimales'; end if;

  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(v_usuario::text, 0));

  select * into v_deuda from public.deudas where id = p_deuda_id and usuario_id = v_usuario for update;
  if not found then raise exception 'Deuda no encontrada'; end if;
  if v_deuda.anulada_at is not null then raise exception 'Esta deuda está anulada'; end if;
  select coalesce(sum(monto),0) into v_pagado from public.deuda_pagos
    where deuda_id = p_deuda_id and anulado_at is null;
  if p_monto > v_deuda.monto_total - v_pagado then
    raise exception 'El pago supera el saldo pendiente (%)', v_deuda.monto_total - v_pagado;
  end if;

  -- Si la categoría fue desactivada después, el pago se registra sin categoría.
  select id into v_categoria from public.categorias
    where id = v_deuda.categoria_id and usuario_id = v_usuario and activa;

  v_movimiento_id := public.finanzas__movimiento(
    p_cuenta_id, case when v_deuda.tipo = 'por_cobrar' then 'ingreso' else 'gasto' end,
    p_monto, v_deuda.destino_dinero,
    left(case when v_deuda.tipo = 'por_cobrar' then 'Cobro a ' else 'Pago a ' end || v_deuda.persona
      || coalesce(': ' || v_deuda.concepto, ''), 300),
    v_categoria, p_operacion_id, p_fecha, 'deuda');

  insert into public.deuda_pagos (usuario_id,deuda_id,monto,fecha,movimiento_id,operacion_id)
  values (v_usuario,p_deuda_id,p_monto,coalesce(p_fecha,(now() at time zone 'America/Lima')::date),
    v_movimiento_id,p_operacion_id);
end;
$$;

create function public.deudas_anular_pago(p_pago_id uuid, p_operacion_id uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  v_usuario uuid := auth.uid();
  v_pago public.deuda_pagos%rowtype;
begin
  if v_usuario is null then raise exception 'Debes iniciar sesión'; end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(v_usuario::text, 0));
  select * into v_pago from public.deuda_pagos where id = p_pago_id and usuario_id = v_usuario for update;
  if not found then raise exception 'Pago no encontrado'; end if;
  if v_pago.anulado_at is not null then raise exception 'Este pago ya fue anulado'; end if;
  perform public.finanzas__anular(v_pago.movimiento_id, 'Anulación de pago de deuda', p_operacion_id);
  update public.deuda_pagos set anulado_at = now() where id = p_pago_id;
end;
$$;

-- Extender o reprogramar el vencimiento (null lo quita).
create function public.deudas_reprogramar(p_deuda_id uuid, p_fecha_vencimiento date)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  if auth.uid() is null then raise exception 'Debes iniciar sesión'; end if;
  update public.deudas set fecha_vencimiento = p_fecha_vencimiento
    where id = p_deuda_id and usuario_id = auth.uid() and anulada_at is null;
  if not found then raise exception 'Deuda no encontrada o anulada'; end if;
end;
$$;

-- Función interna: anula una deuda sin pagos activos (y su préstamo inicial, si lo hubo).
create function public.deudas__anular(p_deuda_id uuid, p_operacion_id uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  v_usuario uuid := auth.uid();
  v_deuda public.deudas%rowtype;
begin
  select * into v_deuda from public.deudas where id = p_deuda_id and usuario_id = v_usuario for update;
  if not found then raise exception 'Deuda no encontrada'; end if;
  if v_deuda.anulada_at is not null then raise exception 'Esta deuda ya fue anulada'; end if;
  if exists (select 1 from public.deuda_pagos where deuda_id = p_deuda_id and anulado_at is null) then
    raise exception 'Primero anula los pagos registrados de esta deuda';
  end if;
  if v_deuda.movimiento_inicial_id is not null then
    perform public.finanzas__anular(v_deuda.movimiento_inicial_id, 'Anulación de deuda', p_operacion_id);
  end if;
  update public.deudas set anulada_at = now() where id = p_deuda_id;
end;
$$;

create function public.deudas_anular(p_deuda_id uuid, p_operacion_id uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  v_usuario uuid := auth.uid();
  v_origen text;
begin
  if v_usuario is null then raise exception 'Debes iniciar sesión'; end if;
  if p_operacion_id is null then raise exception 'Falta el identificador de operación'; end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(v_usuario::text, 0));
  select origen into v_origen from public.deudas where id = p_deuda_id and usuario_id = v_usuario;
  if not found then raise exception 'Deuda no encontrada'; end if;
  if v_origen = 'venta' then raise exception 'Esta deuda viene de una venta fiada: anula la venta desde Negocio'; end if;
  perform public.deudas__anular(p_deuda_id, p_operacion_id);
end;
$$;

-- ---------------------------------------------------------------------------
-- 3. Negocio: productos, compras, ventas e inventario
-- ---------------------------------------------------------------------------
create table public.productos (
  id uuid primary key default gen_random_uuid(),
  usuario_id uuid not null references auth.users(id) on delete cascade,
  nombre text not null check (length(btrim(nombre)) between 1 and 80),
  precio_venta numeric(14,2) not null default 0 check (precio_venta >= 0),
  costo_promedio numeric(14,4) not null default 0 check (costo_promedio >= 0),
  stock integer not null default 0 check (stock >= 0),
  stock_minimo integer not null default 0 check (stock_minimo >= 0),
  fecha_vencimiento date,
  activo boolean not null default true,
  fecha_creacion timestamptz not null default now(),
  fecha_actualizacion timestamptz not null default now()
);
create unique index productos_nombre_unico on public.productos (usuario_id, lower(nombre));

create table public.inventario_ajustes (
  id uuid primary key default gen_random_uuid(),
  usuario_id uuid not null references auth.users(id) on delete cascade,
  producto_id uuid not null references public.productos(id) on delete cascade,
  stock_anterior integer not null,
  stock_nuevo integer not null check (stock_nuevo >= 0),
  costo_unitario numeric(14,4),
  motivo text check (motivo is null or length(motivo) <= 300),
  fecha_creacion timestamptz not null default now()
);
create index inventario_ajustes_producto_idx on public.inventario_ajustes (producto_id, fecha_creacion desc);

create table public.compras (
  id uuid primary key default gen_random_uuid(),
  usuario_id uuid not null references auth.users(id) on delete cascade,
  fecha date not null,
  proveedor text check (proveedor is null or length(proveedor) <= 80),
  total numeric(14,2) not null check (total > 0),
  cuenta_id uuid not null references public.cuentas(id),
  destino_dinero text not null check (destino_dinero in ('personal','negocio','ahorros')),
  movimiento_id uuid not null references public.movimientos(id),
  nota text check (nota is null or length(nota) <= 300),
  operacion_id uuid not null,
  anulada_at timestamptz,
  fecha_creacion timestamptz not null default now(),
  constraint compras_operacion_unica unique (usuario_id, operacion_id)
);
create index compras_usuario_idx on public.compras (usuario_id, fecha desc);

create table public.compra_items (
  id uuid primary key default gen_random_uuid(),
  usuario_id uuid not null references auth.users(id) on delete cascade,
  compra_id uuid not null references public.compras(id) on delete cascade,
  producto_id uuid not null references public.productos(id),
  cantidad integer not null check (cantidad > 0),
  subtotal numeric(14,2) not null check (subtotal >= 0),
  costo_unitario numeric(14,4) not null check (costo_unitario >= 0),
  fecha_vencimiento date
);
create index compra_items_compra_idx on public.compra_items (compra_id);

create table public.ventas (
  id uuid primary key default gen_random_uuid(),
  usuario_id uuid not null references auth.users(id) on delete cascade,
  fecha date not null,
  cliente text check (cliente is null or length(cliente) <= 80),
  total numeric(14,2) not null check (total > 0),
  costo_total numeric(14,2) not null check (costo_total >= 0),
  cuenta_id uuid references public.cuentas(id),
  movimiento_id uuid references public.movimientos(id),
  deuda_id uuid references public.deudas(id),
  nota text check (nota is null or length(nota) <= 300),
  operacion_id uuid not null,
  anulada_at timestamptz,
  fecha_creacion timestamptz not null default now(),
  constraint ventas_operacion_unica unique (usuario_id, operacion_id),
  -- Una venta es cobrada (movimiento) o fiada (deuda), nunca ambas ni ninguna.
  constraint ventas_cobro_check check ((movimiento_id is not null) <> (deuda_id is not null))
);
create index ventas_usuario_idx on public.ventas (usuario_id, fecha desc);

create table public.venta_items (
  id uuid primary key default gen_random_uuid(),
  usuario_id uuid not null references auth.users(id) on delete cascade,
  venta_id uuid not null references public.ventas(id) on delete cascade,
  producto_id uuid not null references public.productos(id),
  cantidad integer not null check (cantidad > 0),
  precio_unitario numeric(14,2) not null check (precio_unitario >= 0),
  costo_unitario numeric(14,4) not null check (costo_unitario >= 0),
  subtotal numeric(14,2) not null check (subtotal >= 0)
);
create index venta_items_venta_idx on public.venta_items (venta_id);

-- Ventas y ganancia por mes. La ganancia es total menos costo de lo vendido.
create view public.negocio_resumen_mensual with (security_invoker = true) as
select usuario_id, to_char(fecha, 'YYYY-MM') as mes,
  sum(total)::numeric(14,2) as ventas, sum(costo_total)::numeric(14,2) as costo,
  (sum(total) - sum(costo_total))::numeric(14,2) as ganancia, count(*)::integer as cantidad
from public.ventas where anulada_at is null
group by usuario_id, 2;

-- Crear (p_id null) o editar un producto. El stock y el costo no se editan aquí.
create function public.productos_guardar(
  p_id uuid, p_nombre text, p_precio_venta numeric, p_stock_minimo integer,
  p_fecha_vencimiento date, p_activo boolean
) returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  v_usuario uuid := auth.uid();
  v_id uuid;
begin
  if v_usuario is null then raise exception 'Debes iniciar sesión'; end if;
  if p_nombre is null or length(btrim(p_nombre)) not between 1 and 80 then
    raise exception 'El nombre del producto debe tener entre 1 y 80 caracteres';
  end if;
  if p_precio_venta is null or p_precio_venta < 0 or p_precio_venta <> round(p_precio_venta,2) then
    raise exception 'El precio de venta no es válido';
  end if;
  if p_stock_minimo is null or p_stock_minimo < 0 then raise exception 'El stock mínimo no es válido'; end if;
  if exists (select 1 from public.productos where usuario_id = v_usuario
      and lower(nombre) = lower(btrim(p_nombre)) and (p_id is null or id <> p_id)) then
    raise exception 'Ya tienes un producto con ese nombre';
  end if;
  if p_id is null then
    insert into public.productos (usuario_id,nombre,precio_venta,stock_minimo,fecha_vencimiento)
    values (v_usuario,btrim(p_nombre),p_precio_venta,p_stock_minimo,p_fecha_vencimiento)
    returning id into v_id;
  else
    update public.productos set nombre = btrim(p_nombre), precio_venta = p_precio_venta,
      stock_minimo = p_stock_minimo, fecha_vencimiento = p_fecha_vencimiento,
      activo = coalesce(p_activo, activo), fecha_actualizacion = now()
    where id = p_id and usuario_id = v_usuario returning id into v_id;
    if v_id is null then raise exception 'Producto no encontrado'; end if;
  end if;
  return v_id;
end;
$$;

-- Ajuste manual de stock (inventario inicial, merma, consumo propio). No mueve dinero.
-- Al aumentar se indica el costo unitario para mantener el costo promedio.
create function public.productos_ajustar_stock(
  p_producto_id uuid, p_nuevo_stock integer, p_costo_unitario numeric, p_motivo text
) returns void
language plpgsql security definer set search_path = ''
as $$
declare
  v_usuario uuid := auth.uid();
  v_prod public.productos%rowtype;
  v_extra integer;
begin
  if v_usuario is null then raise exception 'Debes iniciar sesión'; end if;
  if p_nuevo_stock is null or p_nuevo_stock < 0 then raise exception 'El stock no puede ser negativo'; end if;
  if p_motivo is not null and length(p_motivo) > 300 then raise exception 'Motivo demasiado largo'; end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(v_usuario::text, 0));
  select * into v_prod from public.productos where id = p_producto_id and usuario_id = v_usuario for update;
  if not found then raise exception 'Producto no encontrado'; end if;
  if p_nuevo_stock = v_prod.stock then raise exception 'El stock ya tiene ese valor'; end if;
  v_extra := p_nuevo_stock - v_prod.stock;
  if v_extra > 0 then
    if p_costo_unitario is null or p_costo_unitario < 0 then
      raise exception 'Indica cuánto te costó cada unidad que agregas';
    end if;
    update public.productos set
      costo_promedio = round((stock * costo_promedio + v_extra * p_costo_unitario) / p_nuevo_stock, 4),
      stock = p_nuevo_stock, fecha_actualizacion = now()
    where id = p_producto_id;
  else
    update public.productos set stock = p_nuevo_stock, fecha_actualizacion = now() where id = p_producto_id;
  end if;
  insert into public.inventario_ajustes (usuario_id,producto_id,stock_anterior,stock_nuevo,costo_unitario,motivo)
  values (v_usuario,p_producto_id,v_prod.stock,p_nuevo_stock,
    case when v_extra > 0 then p_costo_unitario else null end, nullif(btrim(p_motivo),''));
end;
$$;

-- Compra de inventario: un solo gasto en Finanzas, sube el stock y actualiza el costo promedio.
-- p_items: [{"producto_id": uuid, "cantidad": entero, "subtotal": pagado por esa línea, "fecha_vencimiento": fecha|null}]
create function public.compras_registrar(
  p_items jsonb, p_cuenta_id uuid, p_destino text, p_proveedor text,
  p_nota text, p_fecha date, p_operacion_id uuid
) returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  v_usuario uuid := auth.uid();
  v_item jsonb;
  v_producto uuid;
  v_cantidad integer;
  v_subtotal numeric;
  v_vence date;
  v_total numeric := 0;
  v_movimiento_id uuid;
  v_compra_id uuid;
begin
  if v_usuario is null then raise exception 'Debes iniciar sesión'; end if;
  if p_operacion_id is null then raise exception 'Falta el identificador de operación'; end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) not between 1 and 100 then
    raise exception 'Agrega al menos un producto a la compra';
  end if;
  if p_proveedor is not null and length(p_proveedor) > 80 then raise exception 'Nombre de proveedor demasiado largo'; end if;
  if p_nota is not null and length(p_nota) > 300 then raise exception 'Nota demasiado larga'; end if;

  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(v_usuario::text, 0));

  for v_item in select * from jsonb_array_elements(p_items) loop
    begin
      v_producto := (v_item->>'producto_id')::uuid;
      v_cantidad := (v_item->>'cantidad')::integer;
      v_subtotal := (v_item->>'subtotal')::numeric;
      v_vence := nullif(v_item->>'fecha_vencimiento','')::date;
    exception when others then
      raise exception 'Hay un producto con datos no válidos en la compra';
    end;
    if v_producto is null or v_cantidad is null or v_cantidad <= 0
       or v_subtotal is null or v_subtotal < 0 or v_subtotal <> round(v_subtotal,2) then
      raise exception 'Revisa cantidades y montos: deben ser positivos y con hasta dos decimales';
    end if;
    if not exists (select 1 from public.productos where id = v_producto and usuario_id = v_usuario and activo) then
      raise exception 'Producto no encontrado o inactivo';
    end if;
    v_total := v_total + v_subtotal;
  end loop;
  if v_total <= 0 then raise exception 'El total de la compra debe ser mayor que cero'; end if;

  v_movimiento_id := public.finanzas__movimiento(p_cuenta_id,'gasto',v_total,coalesce(p_destino,'negocio'),
    left('Compra de inventario' || coalesce(': ' || nullif(btrim(p_proveedor),''), ''), 300),
    null,p_operacion_id,p_fecha,'compra');

  insert into public.compras (usuario_id,fecha,proveedor,total,cuenta_id,destino_dinero,movimiento_id,nota,operacion_id)
  values (v_usuario,coalesce(p_fecha,(now() at time zone 'America/Lima')::date),nullif(btrim(p_proveedor),''),
    v_total,p_cuenta_id,coalesce(p_destino,'negocio'),v_movimiento_id,nullif(btrim(p_nota),''),p_operacion_id)
  returning id into v_compra_id;

  for v_item in select * from jsonb_array_elements(p_items) loop
    v_producto := (v_item->>'producto_id')::uuid;
    v_cantidad := (v_item->>'cantidad')::integer;
    v_subtotal := (v_item->>'subtotal')::numeric;
    v_vence := nullif(v_item->>'fecha_vencimiento','')::date;
    insert into public.compra_items (usuario_id,compra_id,producto_id,cantidad,subtotal,costo_unitario,fecha_vencimiento)
    values (v_usuario,v_compra_id,v_producto,v_cantidad,v_subtotal,round(v_subtotal / v_cantidad,4),v_vence);
    update public.productos set
      costo_promedio = round((stock * costo_promedio + v_subtotal) / (stock + v_cantidad), 4),
      fecha_vencimiento = case
        when v_vence is null then (case when stock = 0 then null else fecha_vencimiento end)
        when stock > 0 and fecha_vencimiento is not null then least(fecha_vencimiento, v_vence)
        else v_vence end,
      stock = stock + v_cantidad, fecha_actualizacion = now()
    where id = v_producto;
  end loop;
  return v_compra_id;
end;
$$;

-- Anular una compra: devuelve el dinero y retira el stock (si todavía está disponible).
create function public.compras_anular(p_compra_id uuid, p_operacion_id uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  v_usuario uuid := auth.uid();
  v_compra public.compras%rowtype;
  v_item record;
  v_prod public.productos%rowtype;
begin
  if v_usuario is null then raise exception 'Debes iniciar sesión'; end if;
  if p_operacion_id is null then raise exception 'Falta el identificador de operación'; end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(v_usuario::text, 0));
  select * into v_compra from public.compras where id = p_compra_id and usuario_id = v_usuario for update;
  if not found then raise exception 'Compra no encontrada'; end if;
  if v_compra.anulada_at is not null then raise exception 'Esta compra ya fue anulada'; end if;

  for v_item in select producto_id, sum(cantidad)::integer as cantidad, sum(subtotal) as subtotal
      from public.compra_items where compra_id = p_compra_id group by producto_id loop
    select * into v_prod from public.productos where id = v_item.producto_id for update;
    if v_prod.stock < v_item.cantidad then
      raise exception 'No se puede anular: ya vendiste parte de "%" de esta compra', v_prod.nombre;
    end if;
    update public.productos set
      costo_promedio = case when stock - v_item.cantidad > 0
        then greatest(0, round((stock * costo_promedio - v_item.subtotal) / (stock - v_item.cantidad), 4))
        else costo_promedio end,
      stock = stock - v_item.cantidad, fecha_actualizacion = now()
    where id = v_item.producto_id;
  end loop;

  perform public.finanzas__anular(v_compra.movimiento_id, 'Anulación de compra', p_operacion_id);
  update public.compras set anulada_at = now() where id = p_compra_id;
end;
$$;

-- Venta: baja el stock y guarda el costo de lo vendido para calcular la ganancia.
-- Con cuenta: se cobra ahora (un ingreso en Finanzas). Sin cuenta: venta fiada (deuda por cobrar).
-- p_items: [{"producto_id": uuid, "cantidad": entero, "precio_unitario": precio}]
create function public.ventas_registrar(
  p_items jsonb, p_cuenta_id uuid, p_cliente text, p_fecha_vencimiento date,
  p_nota text, p_fecha date, p_operacion_id uuid
) returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  v_usuario uuid := auth.uid();
  v_hoy date := (now() at time zone 'America/Lima')::date;
  v_item jsonb;
  v_producto uuid;
  v_cantidad integer;
  v_precio numeric;
  v_prod public.productos%rowtype;
  v_total numeric := 0;
  v_costo numeric := 0;
  v_categoria uuid;
  v_movimiento_id uuid;
  v_deuda_id uuid;
  v_venta_id uuid := gen_random_uuid();
  v_cliente text := nullif(btrim(p_cliente),'');
begin
  if v_usuario is null then raise exception 'Debes iniciar sesión'; end if;
  if p_operacion_id is null then raise exception 'Falta el identificador de operación'; end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) not between 1 and 100 then
    raise exception 'Agrega al menos un producto a la venta';
  end if;
  if v_cliente is not null and length(v_cliente) > 80 then raise exception 'Nombre de cliente demasiado largo'; end if;
  if p_nota is not null and length(p_nota) > 300 then raise exception 'Nota demasiado larga'; end if;
  if p_cuenta_id is null and v_cliente is null then
    raise exception 'Para una venta fiada escribe el nombre del cliente';
  end if;
  perform public.finanzas_fecha_operacion(p_fecha);

  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(v_usuario::text, 0));

  -- Primera pasada: validar, bloquear productos y calcular total y costo.
  for v_item in select * from jsonb_array_elements(p_items) loop
    begin
      v_producto := (v_item->>'producto_id')::uuid;
      v_cantidad := (v_item->>'cantidad')::integer;
      v_precio := (v_item->>'precio_unitario')::numeric;
    exception when others then
      raise exception 'Hay un producto con datos no válidos en la venta';
    end;
    if v_producto is null or v_cantidad is null or v_cantidad <= 0
       or v_precio is null or v_precio < 0 or v_precio <> round(v_precio,2) then
      raise exception 'Revisa cantidades y precios: deben ser positivos y con hasta dos decimales';
    end if;
    select * into v_prod from public.productos
      where id = v_producto and usuario_id = v_usuario and activo for update;
    if not found then raise exception 'Producto no encontrado o inactivo'; end if;
    v_total := v_total + v_cantidad * v_precio;
    v_costo := v_costo + v_cantidad * v_prod.costo_promedio;
  end loop;
  if v_total <= 0 then raise exception 'El total de la venta debe ser mayor que cero'; end if;

  select id into v_categoria from public.categorias
    where usuario_id = v_usuario and tipo = 'ingreso' and activa and lower(nombre) = 'ventas' limit 1;

  if p_cuenta_id is not null then
    v_movimiento_id := public.finanzas__movimiento(p_cuenta_id,'ingreso',v_total,'negocio',
      left('Venta' || coalesce(' a ' || v_cliente, ''), 300),v_categoria,p_operacion_id,p_fecha,'venta');
  else
    insert into public.deudas (usuario_id,tipo,persona,concepto,monto_total,destino_dinero,categoria_id,
      fecha_origen,fecha_vencimiento,origen,operacion_id)
    values (v_usuario,'por_cobrar',v_cliente,'Venta fiada',v_total,'negocio',v_categoria,
      coalesce(p_fecha,v_hoy),p_fecha_vencimiento,'venta',p_operacion_id)
    returning id into v_deuda_id;
  end if;

  insert into public.ventas (id,usuario_id,fecha,cliente,total,costo_total,cuenta_id,movimiento_id,deuda_id,nota,operacion_id)
  values (v_venta_id,v_usuario,coalesce(p_fecha,v_hoy),v_cliente,v_total,round(v_costo,2),p_cuenta_id,
    v_movimiento_id,v_deuda_id,nullif(btrim(p_nota),''),p_operacion_id);

  -- Segunda pasada: bajar stock y guardar cada línea con su costo.
  for v_item in select * from jsonb_array_elements(p_items) loop
    v_producto := (v_item->>'producto_id')::uuid;
    v_cantidad := (v_item->>'cantidad')::integer;
    v_precio := (v_item->>'precio_unitario')::numeric;
    update public.productos set stock = stock - v_cantidad, fecha_actualizacion = now()
      where id = v_producto and stock >= v_cantidad returning * into v_prod;
    if not found then
      select * into v_prod from public.productos where id = v_producto;
      raise exception 'Stock insuficiente de "%": quedan %', v_prod.nombre, v_prod.stock;
    end if;
    insert into public.venta_items (usuario_id,venta_id,producto_id,cantidad,precio_unitario,costo_unitario,subtotal)
    values (v_usuario,v_venta_id,v_producto,v_cantidad,v_precio,v_prod.costo_promedio,round(v_cantidad * v_precio,2));
  end loop;
  return v_venta_id;
end;
$$;

-- Anular una venta: devuelve el stock y revierte el cobro o la deuda.
create function public.ventas_anular(p_venta_id uuid, p_operacion_id uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  v_usuario uuid := auth.uid();
  v_venta public.ventas%rowtype;
  v_item record;
begin
  if v_usuario is null then raise exception 'Debes iniciar sesión'; end if;
  if p_operacion_id is null then raise exception 'Falta el identificador de operación'; end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(v_usuario::text, 0));
  select * into v_venta from public.ventas where id = p_venta_id and usuario_id = v_usuario for update;
  if not found then raise exception 'Venta no encontrada'; end if;
  if v_venta.anulada_at is not null then raise exception 'Esta venta ya fue anulada'; end if;

  if v_venta.movimiento_id is not null then
    perform public.finanzas__anular(v_venta.movimiento_id, 'Anulación de venta', p_operacion_id);
  else
    perform public.deudas__anular(v_venta.deuda_id, p_operacion_id);
  end if;

  for v_item in select producto_id, cantidad, costo_unitario from public.venta_items where venta_id = p_venta_id loop
    update public.productos set
      costo_promedio = round((stock * costo_promedio + v_item.cantidad * v_item.costo_unitario) / (stock + v_item.cantidad), 4),
      stock = stock + v_item.cantidad, fecha_actualizacion = now()
    where id = v_item.producto_id;
  end loop;
  update public.ventas set anulada_at = now() where id = p_venta_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- 4. Tablas de apoyo sin dinero: pedidos, metas de ahorro y hojas de notas
-- ---------------------------------------------------------------------------
create table public.pedidos (
  id uuid primary key default gen_random_uuid(),
  usuario_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  cliente text not null check (length(btrim(cliente)) between 1 and 80),
  detalle text not null check (length(btrim(detalle)) between 1 and 500),
  monto_estimado numeric(14,2) check (monto_estimado is null or monto_estimado >= 0),
  fecha_entrega date,
  estado text not null default 'pendiente' check (estado in ('pendiente','entregado','cancelado')),
  fecha_creacion timestamptz not null default now(),
  fecha_actualizacion timestamptz not null default now()
);
create index pedidos_usuario_idx on public.pedidos (usuario_id, fecha_creacion desc);

create table public.metas_ahorro (
  id uuid primary key default gen_random_uuid(),
  usuario_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  nombre text not null check (length(btrim(nombre)) between 1 and 80),
  monto_objetivo numeric(14,2) not null check (monto_objetivo > 0),
  monto_actual numeric(14,2) not null default 0 check (monto_actual >= 0),
  fecha_objetivo date,
  fecha_creacion timestamptz not null default now(),
  fecha_actualizacion timestamptz not null default now()
);
create index metas_ahorro_usuario_idx on public.metas_ahorro (usuario_id, fecha_creacion);

create table public.hojas (
  id uuid primary key default gen_random_uuid(),
  usuario_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  titulo text not null check (length(btrim(titulo)) between 1 and 120),
  contenido text not null default '' check (length(contenido) <= 20000),
  fecha_creacion timestamptz not null default now(),
  fecha_actualizacion timestamptz not null default now()
);
create index hojas_usuario_idx on public.hojas (usuario_id, fecha_actualizacion desc);

-- ---------------------------------------------------------------------------
-- 5. Seguridad: RLS y permisos
-- ---------------------------------------------------------------------------
alter table public.deudas enable row level security;
alter table public.deuda_pagos enable row level security;
alter table public.productos enable row level security;
alter table public.inventario_ajustes enable row level security;
alter table public.compras enable row level security;
alter table public.compra_items enable row level security;
alter table public.ventas enable row level security;
alter table public.venta_items enable row level security;
alter table public.pedidos enable row level security;
alter table public.metas_ahorro enable row level security;
alter table public.hojas enable row level security;

-- Tablas con dinero o stock: la app solo lee; escribe mediante funciones validadas.
create policy "Consultar deudas propias" on public.deudas for select to authenticated using ((select auth.uid()) = usuario_id);
create policy "Consultar pagos de deuda propios" on public.deuda_pagos for select to authenticated using ((select auth.uid()) = usuario_id);
create policy "Consultar productos propios" on public.productos for select to authenticated using ((select auth.uid()) = usuario_id);
create policy "Consultar ajustes propios" on public.inventario_ajustes for select to authenticated using ((select auth.uid()) = usuario_id);
create policy "Consultar compras propias" on public.compras for select to authenticated using ((select auth.uid()) = usuario_id);
create policy "Consultar items de compra propios" on public.compra_items for select to authenticated using ((select auth.uid()) = usuario_id);
create policy "Consultar ventas propias" on public.ventas for select to authenticated using ((select auth.uid()) = usuario_id);
create policy "Consultar items de venta propios" on public.venta_items for select to authenticated using ((select auth.uid()) = usuario_id);

-- Tablas de apoyo: el dueño puede leer y escribir sus filas directamente.
create policy "Gestionar pedidos propios" on public.pedidos for all to authenticated
  using ((select auth.uid()) = usuario_id) with check ((select auth.uid()) = usuario_id);
create policy "Gestionar metas propias" on public.metas_ahorro for all to authenticated
  using ((select auth.uid()) = usuario_id) with check ((select auth.uid()) = usuario_id);
create policy "Gestionar hojas propias" on public.hojas for all to authenticated
  using ((select auth.uid()) = usuario_id) with check ((select auth.uid()) = usuario_id);

revoke all on public.deudas, public.deuda_pagos, public.productos, public.inventario_ajustes,
  public.compras, public.compra_items, public.ventas, public.venta_items,
  public.pedidos, public.metas_ahorro, public.hojas,
  public.deudas_resumen, public.finanzas_resumen_mensual, public.negocio_resumen_mensual
  from public, anon, authenticated;
grant select on public.deudas, public.deuda_pagos, public.productos, public.inventario_ajustes,
  public.compras, public.compra_items, public.ventas, public.venta_items,
  public.deudas_resumen, public.finanzas_resumen_mensual, public.negocio_resumen_mensual
  to authenticated;
grant select, insert, update, delete on public.pedidos, public.metas_ahorro, public.hojas to authenticated;

-- Funciones internas: nadie las invoca desde la app.
revoke all on function public.finanzas__movimiento(uuid,text,numeric,text,text,uuid,uuid,date,text) from public, anon, authenticated;
revoke all on function public.finanzas__anular(uuid,text,uuid) from public, anon, authenticated;
revoke all on function public.deudas__anular(uuid,uuid) from public, anon, authenticated;

-- Funciones públicas: solo el rol autenticado.
revoke all on function public.finanzas_actualizar_cuenta(uuid,text,boolean) from public, anon, authenticated;
revoke all on function public.deudas_crear(text,text,text,numeric,text,uuid,date,uuid,uuid) from public, anon, authenticated;
revoke all on function public.deudas_registrar_pago(uuid,numeric,uuid,date,uuid) from public, anon, authenticated;
revoke all on function public.deudas_anular_pago(uuid,uuid) from public, anon, authenticated;
revoke all on function public.deudas_reprogramar(uuid,date) from public, anon, authenticated;
revoke all on function public.deudas_anular(uuid,uuid) from public, anon, authenticated;
revoke all on function public.productos_guardar(uuid,text,numeric,integer,date,boolean) from public, anon, authenticated;
revoke all on function public.productos_ajustar_stock(uuid,integer,numeric,text) from public, anon, authenticated;
revoke all on function public.compras_registrar(jsonb,uuid,text,text,text,date,uuid) from public, anon, authenticated;
revoke all on function public.compras_anular(uuid,uuid) from public, anon, authenticated;
revoke all on function public.ventas_registrar(jsonb,uuid,text,date,text,date,uuid) from public, anon, authenticated;
revoke all on function public.ventas_anular(uuid,uuid) from public, anon, authenticated;
grant execute on function public.finanzas_actualizar_cuenta(uuid,text,boolean) to authenticated;
grant execute on function public.deudas_crear(text,text,text,numeric,text,uuid,date,uuid,uuid) to authenticated;
grant execute on function public.deudas_registrar_pago(uuid,numeric,uuid,date,uuid) to authenticated;
grant execute on function public.deudas_anular_pago(uuid,uuid) to authenticated;
grant execute on function public.deudas_reprogramar(uuid,date) to authenticated;
grant execute on function public.deudas_anular(uuid,uuid) to authenticated;
grant execute on function public.productos_guardar(uuid,text,numeric,integer,date,boolean) to authenticated;
grant execute on function public.productos_ajustar_stock(uuid,integer,numeric,text) to authenticated;
grant execute on function public.compras_registrar(jsonb,uuid,text,text,text,date,uuid) to authenticated;
grant execute on function public.compras_anular(uuid,uuid) to authenticated;
grant execute on function public.ventas_registrar(jsonb,uuid,text,date,text,date,uuid) to authenticated;
grant execute on function public.ventas_anular(uuid,uuid) to authenticated;
