-- Ejecutar SOLO en una base local aislada que ya tenga el esquema y AMBAS migraciones de Finanzas.
-- Toda la prueba se revierte al terminar.
\set ON_ERROR_STOP on
begin;

insert into auth.users (id,instance_id,aud,role,email,encrypted_password,raw_user_meta_data,created_at,updated_at)
values
 ('00000000-0000-0000-0000-0000000000c3','00000000-0000-0000-0000-000000000000','authenticated','authenticated','finanzas-c@example.invalid','', '{"nombre_usuario":"finanzas_c","nombre":"Prueba C"}',now(),now()),
 ('00000000-0000-0000-0000-0000000000d4','00000000-0000-0000-0000-000000000000','authenticated','authenticated','finanzas-d@example.invalid','', '{"nombre_usuario":"finanzas_d","nombre":"Prueba D"}',now(),now());

select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-0000000000c3',true);
set local role authenticated;

-- Categorías sugeridas (idempotentes) y personalizadas.
select public.finanzas_crear_categorias_sugeridas();
select public.finanzas_crear_categorias_sugeridas();
select public.finanzas_crear_categoria('Propinas','ingreso');

do $$
begin
  if (select count(*) from public.categorias) <> 10 then raise exception 'Categorías sugeridas duplicadas o faltantes'; end if;
  begin
    perform public.finanzas_crear_categoria('propinas','ingreso');
    raise exception 'Se permitió duplicar una categoría';
  exception when others then
    if sqlerrm = 'Se permitió duplicar una categoría' then raise; end if;
  end;
  begin
    insert into public.categorias (usuario_id,nombre,tipo) values (auth.uid(),'Directa','gasto');
    raise exception 'Se permitió insertar una categoría directamente';
  exception when others then
    if sqlerrm = 'Se permitió insertar una categoría directamente' then raise; end if;
  end;
end;
$$;

select public.finanzas_crear_cuenta('Yape','billetera_digital',null) as yape \gset
select public.finanzas_crear_cuenta('Efectivo','efectivo',null) as efectivo \gset
select set_config('test.yape_id', :'yape', true);
select public.finanzas_registrar_saldo_inicial(:'yape'::uuid,100,100,0,0,'00000000-0000-0000-0000-000000000201');
select public.finanzas_registrar_saldo_inicial(:'efectivo'::uuid,0,0,0,0,'00000000-0000-0000-0000-000000000202');

-- Ingreso del trabajo con fecha pasada y categoría.
select public.finanzas_registrar_movimiento(:'yape'::uuid,'ingreso',60,'personal','Pago del sábado',
  (select id from public.categorias where nombre='Trabajo'),'00000000-0000-0000-0000-000000000203',
  ((now() at time zone 'America/Lima')::date - 3));
-- Gasto de hoy sin fecha (se usa la actual).
select public.finanzas_registrar_movimiento(:'yape'::uuid,'gasto',30,'personal','Almuerzo',null,'00000000-0000-0000-0000-000000000204');
select public.finanzas_transferir(:'yape'::uuid,:'efectivo'::uuid,50,'Retiro','00000000-0000-0000-0000-000000000205',
  ((now() at time zone 'America/Lima')::date - 1));

do $$
begin
  if (select (fecha_movimiento at time zone 'America/Lima')::date from public.movimientos where descripcion='Pago del sábado')
     <> (now() at time zone 'America/Lima')::date - 3 then
    raise exception 'La fecha elegida no se guardó';
  end if;
  if (select sum(saldo) from public.finanzas_saldos_cuentas) <> 130
     or (select sum(monto) from public.asignaciones_dinero) <> 130 then
    raise exception 'Los totales no cuadran antes de anular';
  end if;
  begin
    perform public.finanzas_registrar_movimiento(current_setting('test.yape_id')::uuid,'gasto',1,'personal',null,null,
      '00000000-0000-0000-0000-000000000206',(now() at time zone 'America/Lima')::date + 1);
    raise exception 'Se permitió una fecha futura';
  exception when others then
    if sqlerrm = 'Se permitió una fecha futura' then raise; end if;
  end;
end;
$$;

-- Anular gasto: el dinero vuelve a la cuenta y al destino.
select public.finanzas_anular_movimiento((select id from public.movimientos where descripcion='Almuerzo'),'Registrado por error','00000000-0000-0000-0000-000000000207');

do $$
begin
  if (select saldo from public.finanzas_saldos_cuentas where nombre='Yape') <> 110
     or (select monto from public.asignaciones_dinero where destino='personal') <> 160 then
    raise exception 'Anular el gasto no devolvió el dinero';
  end if;
  begin
    perform public.finanzas_anular_movimiento((select id from public.movimientos where descripcion='Almuerzo'),null,'00000000-0000-0000-0000-000000000208');
    raise exception 'Se permitió anular dos veces';
  exception when others then
    if sqlerrm = 'Se permitió anular dos veces' then raise; end if;
  end;
  begin
    perform public.finanzas_anular_movimiento((select id from public.movimientos where tipo='saldo_inicial' limit 1),null,'00000000-0000-0000-0000-000000000209');
    raise exception 'Se permitió anular un saldo inicial';
  exception when others then
    if sqlerrm = 'Se permitió anular un saldo inicial' then raise; end if;
  end;
end;
$$;

-- Anular transferencia: se anulan ambos lados.
select public.finanzas_anular_movimiento((select id from public.movimientos where descripcion='Retiro' and direccion_transferencia='entrada'),null,'00000000-0000-0000-0000-000000000210');
-- Anular ingreso: el dinero sale de la cuenta y del destino.
select public.finanzas_anular_movimiento((select id from public.movimientos where descripcion='Pago del sábado'),null,'00000000-0000-0000-0000-000000000211');

do $$
begin
  if (select count(*) from public.movimientos where anulado_at is not null) <> 4 then
    raise exception 'No se marcaron todos los movimientos anulados';
  end if;
  if (select saldo from public.finanzas_saldos_cuentas where nombre='Yape') <> 100
     or (select saldo from public.finanzas_saldos_cuentas where nombre='Efectivo') <> 0
     or (select sum(monto) from public.asignaciones_dinero) <> 100 then
    raise exception 'Los totales no cuadran después de anular';
  end if;
  if (select count(*) from public.historial_asignaciones where tipo='anulacion') <> 3 then
    raise exception 'Las anulaciones no quedaron en el historial';
  end if;
end;
$$;

-- Un ingreso ya gastado no se puede anular si dejaría saldos negativos.
select public.finanzas_registrar_movimiento(:'yape'::uuid,'ingreso',20,'negocio','Venta',null,'00000000-0000-0000-0000-000000000212');
select public.finanzas_registrar_movimiento(:'yape'::uuid,'gasto',20,'negocio','Compra',null,'00000000-0000-0000-0000-000000000213');
do $$
begin
  begin
    perform public.finanzas_anular_movimiento((select id from public.movimientos where descripcion='Venta'),null,'00000000-0000-0000-0000-000000000214');
    raise exception 'Se permitió dejar un destino negativo';
  exception when others then
    if sqlerrm = 'Se permitió dejar un destino negativo' then raise; end if;
  end;
end;
$$;

-- Otro usuario no puede anular ni ver datos ajenos.
reset role;
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-0000000000d4',true);
set local role authenticated;
do $$
begin
  if (select count(*) from public.categorias) <> 0 or (select count(*) from public.movimientos) <> 0 then
    raise exception 'El segundo usuario puede leer datos ajenos';
  end if;
  begin
    perform public.finanzas_desactivar_categoria((select id from public.categorias limit 1));
    raise exception 'Se permitió tocar una categoría ajena';
  exception when others then
    if sqlerrm = 'Se permitió tocar una categoría ajena' then raise; end if;
  end;
end;
$$;

reset role;
rollback;
\echo Pruebas de categorías, fechas y anulación correctas; cambios revertidos.
