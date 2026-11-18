-- Ejecutar SOLO en una base local aislada que ya tenga el esquema y las TRES migraciones.
-- Toda la prueba se revierte al terminar.
\set ON_ERROR_STOP on
begin;

insert into auth.users (id,instance_id,aud,role,email,encrypted_password,raw_user_meta_data,created_at,updated_at)
values
 ('00000000-0000-0000-0000-0000000000e5','00000000-0000-0000-0000-000000000000','authenticated','authenticated','negocio-e@example.invalid','', '{"nombre_usuario":"negocio_e","nombre":"Prueba E"}',now(),now()),
 ('00000000-0000-0000-0000-0000000000f6','00000000-0000-0000-0000-000000000000','authenticated','authenticated','negocio-f@example.invalid','', '{"nombre_usuario":"negocio_f","nombre":"Prueba F"}',now(),now());

select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-0000000000e5',true);
set local role authenticated;

select public.finanzas_crear_categorias_sugeridas();
select public.finanzas_crear_cuenta('Yape','billetera_digital',null) as yape \gset
select public.finanzas_crear_cuenta('Efectivo','efectivo',null) as efectivo \gset
select public.finanzas_registrar_saldo_inicial(:'yape'::uuid,200,100,100,0,'00000000-0000-0000-0000-000000000301');
select public.finanzas_registrar_saldo_inicial(:'efectivo'::uuid,0,0,0,0,'00000000-0000-0000-0000-000000000302');

-- Función de apoyo para comprobar que el dinero cuadra en cada paso.
create function pg_temp.cuadra(p_yape numeric, p_personal numeric, p_negocio numeric, p_paso text) returns void
language plpgsql as $$
begin
  if (select saldo from public.finanzas_saldos_cuentas where nombre='Yape') <> p_yape
     or (select monto from public.asignaciones_dinero where destino='personal') <> p_personal
     or (select monto from public.asignaciones_dinero where destino='negocio') <> p_negocio
     or (select sum(saldo) from public.finanzas_saldos_cuentas) <> (select sum(monto) from public.asignaciones_dinero) then
    raise exception 'Los saldos no cuadran en: %', p_paso;
  end if;
end;
$$;

-- ---------------- Deudas ----------------
-- Pago pendiente del trabajo: no mueve dinero al crearse.
select public.deudas_crear('por_cobrar','Jefe','Turnos de la semana',80,'personal',
  (select id from public.categorias where nombre='Trabajo'),
  ((now() at time zone 'America/Lima')::date + 7),null,'00000000-0000-0000-0000-000000000310') as trabajo \gset
select pg_temp.cuadra(200,100,100,'crear deuda sin cuenta');

select public.deudas_registrar_pago(:'trabajo'::uuid,30,:'yape'::uuid,null,'00000000-0000-0000-0000-000000000311');
select pg_temp.cuadra(230,130,100,'pago parcial');

do $$
declare v_deuda uuid := (select id from public.deudas where persona='Jefe');
begin
  if (select estado from public.deudas_resumen where id=v_deuda) <> 'parcial'
     or (select saldo from public.deudas_resumen where id=v_deuda) <> 50 then
    raise exception 'El pago parcial no dejó el saldo correcto';
  end if;
  if (select categoria_id from public.movimientos where origen='deuda') is distinct from (select id from public.categorias where nombre='Trabajo') then
    raise exception 'El cobro no heredó la categoría de la deuda';
  end if;
  begin
    perform public.deudas_registrar_pago(v_deuda,60,(select id from public.cuentas where nombre='Yape'),null,'00000000-0000-0000-0000-000000000312');
    raise exception 'Se permitió pagar más que el saldo';
  exception when others then
    if sqlerrm = 'Se permitió pagar más que el saldo' then raise; end if;
  end;
  begin
    perform public.finanzas_anular_movimiento((select id from public.movimientos where origen='deuda'),null,'00000000-0000-0000-0000-000000000313');
    raise exception 'Se permitió anular desde Finanzas un cobro de deuda';
  exception when others then
    if sqlerrm = 'Se permitió anular desde Finanzas un cobro de deuda' then raise; end if;
  end;
  begin
    perform public.deudas_anular(v_deuda,'00000000-0000-0000-0000-000000000314');
    raise exception 'Se permitió anular una deuda con pagos';
  exception when others then
    if sqlerrm = 'Se permitió anular una deuda con pagos' then raise; end if;
  end;
end;
$$;

select public.deudas_registrar_pago(:'trabajo'::uuid,50,:'yape'::uuid,null,'00000000-0000-0000-0000-000000000315');
do $$ begin
  if (select estado from public.deudas_resumen where persona='Jefe') <> 'pagada' then raise exception 'La deuda no quedó pagada'; end if;
end; $$;
select public.deudas_anular_pago((select id from public.deuda_pagos where monto=50),'00000000-0000-0000-0000-000000000316');
select pg_temp.cuadra(230,130,100,'anular pago');
select public.deudas_reprogramar(:'trabajo'::uuid,((now() at time zone 'America/Lima')::date + 30));

-- Préstamo: el dinero sale al crear la deuda y vuelve al anularla.
select public.deudas_crear('por_cobrar','Luis','Préstamo',20,'personal',null,null,:'yape'::uuid,'00000000-0000-0000-0000-000000000317') as prestamo \gset
select pg_temp.cuadra(210,110,100,'préstamo');
select public.deudas_anular(:'prestamo'::uuid,'00000000-0000-0000-0000-000000000318');
select pg_temp.cuadra(230,130,100,'anular préstamo');

-- ---------------- Negocio ----------------
select public.productos_guardar(null,'Galletas',1.50,2,null,null) as galletas \gset
select public.productos_guardar(null,'Jugo',3.50,1,null,null) as jugo \gset
select public.productos_ajustar_stock(:'jugo'::uuid,5,2,'Inventario inicial');

select public.compras_registrar(jsonb_build_array(
  jsonb_build_object('producto_id',:'galletas','cantidad',10,'subtotal',8.50,'fecha_vencimiento','2099-01-31'),
  jsonb_build_object('producto_id',:'jugo','cantidad',5,'subtotal',12.00)
),:'yape'::uuid,'negocio','Tienda Unión',null,null,'00000000-0000-0000-0000-000000000320') as compra \gset
select pg_temp.cuadra(209.50,130,79.50,'compra');

do $$ begin
  if (select stock from public.productos where nombre='Galletas') <> 10
     or (select costo_promedio from public.productos where nombre='Galletas') <> 0.85
     or (select fecha_vencimiento from public.productos where nombre='Galletas') <> date '2099-01-31'
     or (select stock from public.productos where nombre='Jugo') <> 10
     or (select costo_promedio from public.productos where nombre='Jugo') <> 2.2 then
    raise exception 'La compra no actualizó stock o costo promedio';
  end if;
  if (select count(*) from public.movimientos where origen='compra' and tipo='gasto' and monto=20.50) <> 1 then
    raise exception 'La compra no generó exactamente un gasto';
  end if;
end; $$;

-- Venta cobrada: un solo ingreso, baja stock y guarda el costo.
select public.ventas_registrar(jsonb_build_array(
  jsonb_build_object('producto_id',:'galletas','cantidad',4,'precio_unitario',1.50)
),:'yape'::uuid,null,null,null,null,'00000000-0000-0000-0000-000000000321') as venta \gset
select pg_temp.cuadra(215.50,130,85.50,'venta cobrada');

do $$ begin
  if (select total - costo_total from public.ventas where movimiento_id is not null) <> 2.60 then
    raise exception 'La ganancia de la venta no es total menos costo';
  end if;
  if (select stock from public.productos where nombre='Galletas') <> 6 then raise exception 'La venta no bajó el stock'; end if;
  if (select count(*) from public.movimientos where origen='venta') <> 1
     or (select categoria_id from public.movimientos where origen='venta') is distinct from (select id from public.categorias where nombre='Ventas') then
    raise exception 'La venta no generó un único ingreso con categoría Ventas';
  end if;
  begin
    perform public.ventas_registrar(jsonb_build_array(jsonb_build_object('producto_id',(select id from public.productos where nombre='Galletas'),'cantidad',7,'precio_unitario',1.50)),
      (select id from public.cuentas where nombre='Yape'),null,null,null,null,'00000000-0000-0000-0000-000000000322');
    raise exception 'Se permitió vender más que el stock';
  exception when others then
    if sqlerrm = 'Se permitió vender más que el stock' then raise; end if;
  end;
  begin
    perform public.ventas_registrar(jsonb_build_array(jsonb_build_object('producto_id',(select id from public.productos where nombre='Galletas'),'cantidad',1,'precio_unitario',1.50)),
      (select id from public.cuentas where nombre='Yape'),null,null,null,null,'00000000-0000-0000-0000-000000000321');
    raise exception 'Se permitió duplicar una venta al reintentar';
  exception when others then
    if sqlerrm = 'Se permitió duplicar una venta al reintentar' then raise; end if;
  end;
  begin
    perform public.compras_anular((select id from public.compras limit 1),'00000000-0000-0000-0000-000000000323');
    raise exception 'Se permitió anular una compra ya vendida';
  exception when others then
    if sqlerrm = 'Se permitió anular una compra ya vendida' then raise; end if;
  end;
  begin
    insert into public.productos (usuario_id,nombre) values (auth.uid(),'Directo');
    raise exception 'Se permitió insertar un producto directamente';
  exception when others then
    if sqlerrm = 'Se permitió insertar un producto directamente' then raise; end if;
  end;
  if (select stock from public.productos where nombre='Galletas') <> 6 then raise exception 'Un error dejó stock parcial'; end if;
end; $$;
select pg_temp.cuadra(215.50,130,85.50,'errores sin efecto');

-- Venta fiada: no entra dinero; crea una deuda por cobrar ligada a la venta.
select public.ventas_registrar(jsonb_build_array(
  jsonb_build_object('producto_id',:'jugo','cantidad',2,'precio_unitario',3.50)
),null,'Ana',null,null,null,'00000000-0000-0000-0000-000000000330') as fiada \gset
select pg_temp.cuadra(215.50,130,85.50,'venta fiada');

do $$
declare v_deuda uuid := (select id from public.deudas where persona='Ana');
begin
  if (select saldo from public.deudas_resumen where id=v_deuda) <> 7 or (select origen from public.deudas where id=v_deuda) <> 'venta' then
    raise exception 'La venta fiada no creó su deuda';
  end if;
  begin
    perform public.deudas_anular(v_deuda,'00000000-0000-0000-0000-000000000331');
    raise exception 'Se permitió anular desde Deudas una venta fiada';
  exception when others then
    if sqlerrm = 'Se permitió anular desde Deudas una venta fiada' then raise; end if;
  end;
  perform public.deudas_registrar_pago(v_deuda,3,(select id from public.cuentas where nombre='Yape'),null,'00000000-0000-0000-0000-000000000332');
  begin
    perform public.ventas_anular((select id from public.ventas where deuda_id=v_deuda),'00000000-0000-0000-0000-000000000333');
    raise exception 'Se permitió anular una venta fiada con cobros';
  exception when others then
    if sqlerrm = 'Se permitió anular una venta fiada con cobros' then raise; end if;
  end;
  perform public.deudas_anular_pago((select id from public.deuda_pagos where deuda_id=v_deuda),'00000000-0000-0000-0000-000000000334');
end;
$$;

select public.ventas_anular(:'fiada'::uuid,'00000000-0000-0000-0000-000000000335');
select public.ventas_anular(:'venta'::uuid,'00000000-0000-0000-0000-000000000336');
select pg_temp.cuadra(209.50,130,79.50,'anular ventas');
select public.compras_anular(:'compra'::uuid,'00000000-0000-0000-0000-000000000337');
select pg_temp.cuadra(230,130,100,'anular compra');

do $$ begin
  if (select stock from public.productos where nombre='Galletas') <> 0
     or (select stock from public.productos where nombre='Jugo') <> 5
     or (select costo_promedio from public.productos where nombre='Jugo') <> 2 then
    raise exception 'Las anulaciones no devolvieron el inventario a su estado inicial';
  end if;
  if (select estado from public.deudas_resumen where persona='Ana') <> 'anulada' then raise exception 'La deuda de la venta fiada no se anuló'; end if;
  if (select coalesce(sum(ventas),0) from public.negocio_resumen_mensual) <> 0 then raise exception 'El resumen cuenta ventas anuladas'; end if;
  if (select sum(total) from public.finanzas_resumen_mensual where tipo='ingreso') <> 30 then
    raise exception 'El resumen mensual no excluye lo anulado';
  end if;
end; $$;

-- Cuentas: no se desactiva una cuenta con saldo.
do $$ begin
  begin
    perform public.finanzas_actualizar_cuenta((select id from public.cuentas where nombre='Yape'),'Yape',false);
    raise exception 'Se permitió desactivar una cuenta con saldo';
  exception when others then
    if sqlerrm = 'Se permitió desactivar una cuenta con saldo' then raise; end if;
  end;
  perform public.finanzas_actualizar_cuenta((select id from public.cuentas where nombre='Efectivo'),'Billetera',false);
  if (select activa from public.cuentas where nombre='Billetera') then raise exception 'La cuenta no se desactivó'; end if;
end; $$;

-- Tablas de apoyo: escritura directa del dueño.
insert into public.pedidos (cliente,detalle) values ('Ana','2 jugos para el sábado');
insert into public.metas_ahorro (nombre,monto_objetivo) values ('Laptop',1500);
insert into public.hojas (titulo,contenido) values ('Ideas','Probar nuevos productos');

-- Otro usuario no ve ni toca nada.
reset role;
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-0000000000f6',true);
set local role authenticated;
do $$
begin
  if (select count(*) from public.deudas) + (select count(*) from public.productos) + (select count(*) from public.ventas)
     + (select count(*) from public.compras) + (select count(*) from public.pedidos) + (select count(*) from public.metas_ahorro)
     + (select count(*) from public.hojas) + (select count(*) from public.deudas_resumen)
     + (select count(*) from public.finanzas_resumen_mensual) <> 0 then
    raise exception 'El segundo usuario puede leer datos ajenos';
  end if;
  update public.hojas set titulo = 'Ajeno';
  if found then raise exception 'El segundo usuario pudo editar una hoja ajena'; end if;
  begin
    insert into public.pedidos (usuario_id,cliente,detalle) values ('00000000-0000-0000-0000-0000000000e5','X','Y');
    raise exception 'Se permitió crear un pedido a nombre de otro usuario';
  exception when others then
    if sqlerrm = 'Se permitió crear un pedido a nombre de otro usuario' then raise; end if;
  end;
end;
$$;

reset role;
rollback;
\echo Pruebas de deudas, negocio y apoyo correctas; cambios revertidos.
