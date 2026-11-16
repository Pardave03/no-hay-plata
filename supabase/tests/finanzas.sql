-- Ejecutar SOLO en una base local aislada que ya tenga el esquema y la migración.
-- Toda la prueba se revierte al terminar.
\set ON_ERROR_STOP on
begin;

insert into auth.users (id,instance_id,aud,role,email,encrypted_password,raw_user_meta_data,created_at,updated_at)
values
 ('00000000-0000-0000-0000-0000000000a1','00000000-0000-0000-0000-000000000000','authenticated','authenticated','finanzas-a@example.invalid','', '{"nombre_usuario":"finanzas_a","nombre":"Prueba A"}',now(),now()),
 ('00000000-0000-0000-0000-0000000000b2','00000000-0000-0000-0000-000000000000','authenticated','authenticated','finanzas-b@example.invalid','', '{"nombre_usuario":"finanzas_b","nombre":"Prueba B"}',now(),now());

select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-0000000000a1',true);
set local role authenticated;

select public.finanzas_crear_cuenta('Banco / Yape','banco',null) as banco \gset
select public.finanzas_crear_cuenta('Efectivo','efectivo',null) as efectivo \gset
select set_config('test.bank_id', :'banco', true);
select public.finanzas_registrar_saldo_inicial(:'banco'::uuid,100,50,30,20,'00000000-0000-0000-0000-000000000101');
select public.finanzas_registrar_saldo_inicial(:'efectivo'::uuid,0,0,0,0,'00000000-0000-0000-0000-000000000102');
select public.finanzas_registrar_movimiento(:'banco'::uuid,'ingreso',25,'personal','Ingreso de prueba',null,'00000000-0000-0000-0000-000000000103');
select public.finanzas_registrar_movimiento(:'banco'::uuid,'gasto',10,'personal','Gasto de prueba',null,'00000000-0000-0000-0000-000000000104');
select public.finanzas_transferir(:'banco'::uuid,:'efectivo'::uuid,40,'Transferencia de prueba','00000000-0000-0000-0000-000000000105');
select public.finanzas_redistribuir('personal','ahorros',15,'Redistribución de prueba','00000000-0000-0000-0000-000000000106');

do $$
declare
  v_fisico numeric;
  v_destinos numeric;
begin
  select sum(saldo) into v_fisico from public.finanzas_saldos_cuentas;
  select sum(monto) into v_destinos from public.asignaciones_dinero;
  if v_fisico <> 115 or v_destinos <> 115 then raise exception 'Los totales no cuadran'; end if;
  if (select monto from public.asignaciones_dinero where destino='personal') <> 50
     or (select monto from public.asignaciones_dinero where destino='negocio') <> 30
     or (select monto from public.asignaciones_dinero where destino='ahorros') <> 35 then
    raise exception 'La distribución no cuadra';
  end if;
  if (select count(*) from public.movimientos where tipo='transferencia') <> 2 then
    raise exception 'La transferencia no tiene dos lados';
  end if;
  if (select count(*) from public.movimientos where tipo='ingreso') <> 1
     or (select count(*) from public.movimientos where tipo='gasto') <> 1 then
    raise exception 'La transferencia creó un ingreso o gasto ficticio';
  end if;
  if (select count(*) from public.historial_asignaciones where tipo='asignacion_inicial' and monto=0) <> 1 then
    raise exception 'El saldo inicial cero no quedó auditado';
  end if;
  if (select count(*) from public.finanzas_saldos_cuentas where saldo_inicial_definido_at is not null) <> 2 then
    raise exception 'Falta marcar un saldo inicial';
  end if;
end;
$$;

do $$
begin
  begin
    perform public.finanzas_registrar_saldo_inicial((select id from public.cuentas where nombre='Efectivo'),0,0,0,0,'00000000-0000-0000-0000-000000000107');
    raise exception 'Se permitió repetir saldo inicial';
  exception when others then
    if sqlerrm = 'Se permitió repetir saldo inicial' then raise; end if;
  end;
  begin
    perform public.finanzas_registrar_movimiento((select id from public.cuentas where nombre='Banco / Yape'),'gasto',80,'personal','Exceso',null,'00000000-0000-0000-0000-000000000108');
    raise exception 'Se permitió gastar más que el saldo físico';
  exception when others then
    if sqlerrm = 'Se permitió gastar más que el saldo físico' then raise; end if;
  end;
  begin
    perform public.finanzas_registrar_movimiento((select id from public.cuentas where nombre='Banco / Yape'),'gasto',55,'personal','Exceso destino',null,'00000000-0000-0000-0000-000000000109');
    raise exception 'Se permitió gastar más que el destino';
  exception when others then
    if sqlerrm = 'Se permitió gastar más que el destino' then raise; end if;
  end;
  begin
    perform public.finanzas_registrar_movimiento((select id from public.cuentas where nombre='Banco / Yape'),'gasto',10,'personal','Duplicado',null,'00000000-0000-0000-0000-000000000104');
    raise exception 'Se permitió reutilizar identificador de operación';
  exception when others then
    if sqlerrm = 'Se permitió reutilizar identificador de operación' then raise; end if;
  end;
  begin
    perform public.finanzas_transferir((select id from public.cuentas where nombre='Banco / Yape'),'00000000-0000-0000-0000-000000000999',5,null,'00000000-0000-0000-0000-000000000110');
    raise exception 'Se permitió transferir a cuenta ajena o inexistente';
  exception when others then
    if sqlerrm = 'Se permitió transferir a cuenta ajena o inexistente' then raise; end if;
  end;
  begin
    update public.asignaciones_dinero set monto=999 where destino='personal';
    raise exception 'Se permitió modificar un saldo directamente';
  exception when others then
    if sqlerrm = 'Se permitió modificar un saldo directamente' then raise; end if;
  end;
  if (select sum(saldo) from public.finanzas_saldos_cuentas) <> 115
     or (select sum(monto) from public.asignaciones_dinero) <> 115 then
    raise exception 'Un error dejó una operación parcial';
  end if;
end;
$$;

reset role;
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-0000000000b2',true);
set local role authenticated;

do $$
begin
  if (select count(*) from public.finanzas_saldos_cuentas) <> 0
     or (select count(*) from public.asignaciones_dinero) <> 0
     or (select count(*) from public.movimientos) <> 0 then
    raise exception 'El segundo usuario puede leer datos ajenos';
  end if;
  begin
    perform public.finanzas_registrar_movimiento(current_setting('test.bank_id')::uuid,'gasto',1,'personal',null,null,'00000000-0000-0000-0000-000000000111');
    raise exception 'El segundo usuario pudo usar una cuenta ajena';
  exception when others then
    if sqlerrm = 'El segundo usuario pudo usar una cuenta ajena' then raise; end if;
  end;
end;
$$;

reset role;
rollback;
\echo Pruebas locales de Finanzas correctas; cambios revertidos.
