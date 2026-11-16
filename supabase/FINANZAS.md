# Diseño de Finanzas

La migración `20261104191448_finanzas_operaciones_seguras.sql` es incremental. Usa las seis tablas existentes y **no debe aplicarse al remoto sin aprobación explícita**. Aborta si `cuentas`, `movimientos`, `asignaciones_dinero` o `historial_asignaciones` contienen filas: antes de desplegarla hay que volver a comprobar ese supuesto.

## Dos ejes del mismo dinero

- **Cuentas físicas:** `cuentas` representa dónde está el dinero. Banco/Yape puede ser una cuenta física; efectivo, otra. El saldo se calcula a partir de `movimientos` en la vista `finanzas_saldos_cuentas`.
- **Destinos:** `asignaciones_dinero` representa para qué se reserva el dinero: personal, negocio o ahorros. No son cuentas bancarias adicionales.
- **Invariante:** suma de saldos físicos = suma de destinos. La distribución inicial, los ingresos y los gastos actualizan ambos ejes en la misma transacción. Las transferencias modifican solo el eje físico; las redistribuciones, solo el eje de destinos.
- **Saldo inicial:** se confirma una sola vez por cuenta, incluso si es cero. Cero deja una anotación en `historial_asignaciones` sin crear un movimiento de importe cero.

## Operaciones

React invoca cinco funciones RPC: `finanzas_crear_cuenta`, `finanzas_registrar_saldo_inicial`, `finanzas_registrar_movimiento`, `finanzas_transferir` y `finanzas_redistribuir`. Cada una valida `auth.uid()`, entradas y propiedad de cuentas; las escrituras monetarias se serializan por usuario con un bloqueo de transacción. Las funciones de gasto y transferencia rechazan saldos físicos negativos, y gasto y redistribución rechazan destinos negativos. Los errores revierten la operación completa.

El rol `authenticated` puede leer datos propios mediante RLS, pero no tiene `INSERT`, `UPDATE` ni `DELETE` directos sobre cuentas, movimientos, asignaciones o historial. Las RPC son `SECURITY DEFINER`, usan `search_path` vacío y solo conceden `EXECUTE` a `authenticated`. `anon` no puede invocarlas. La vista usa `security_invoker = true` para respetar RLS. Los administradores con privilegios elevados deben mantener estas invariantes si hacen cambios fuera de las RPC.

Cada operación monetaria recibe `operacion_id` generado por el cliente. Los índices únicos impiden duplicar un movimiento o redistribución al reintentar. **Compras y Ventas deben llamar a la misma RPC de ingreso o gasto**, con un identificador estable de su operación de negocio; no deben insertar un segundo movimiento por su cuenta. Este contrato evita contabilizar dos veces una compra o venta cuando se desarrollen esos módulos.

## Pruebas y despliegue

La migración se aplicó únicamente en una base Supabase local aislada que había recibido el dump de `public`. `supabase/tests/finanzas.sql` se ejecutó allí con `ROLLBACK`. Verifica saldos iniciales positivos y cero, ingreso, gasto, transferencia, redistribución, reintentos, fondos insuficientes, lectura entre usuarios y prohibición de escritura directa. También se verificaron localmente los permisos de RPC y `security_invoker`. Los asesores de seguridad locales no reportaron problemas. En una prueba adicional, dos gastos simultáneos de 70 contra un saldo de 100 produjeron un solo gasto aceptado y saldos físico y personal de 30; los datos ficticios se retiraron después.

Antes de cualquier aplicación remota: comprobar de nuevo el esquema y que las cuatro tablas financieras sigan vacías; verificar una copia de seguridad integral recuperable (incluido Auth, si se necesita restaurar perfiles); revisar el SQL y `db push --dry-run --skip-vault`; solicitar aprobación expresa. El despliegue a producción y la prueba visual con datos reales siguen pendientes.
