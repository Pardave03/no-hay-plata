# Activación remota de Finanzas

Proyecto: `ljfikbitkjpooskhfweu`. Esta guía **no autoriza** una aplicación remota.

## Estado comprobado el 2026-11-04

- Organización en plan Free. No hay respaldo diario administrado ni PITR incluido.
- Las seis tablas `public` existen, tienen RLS activo y conservan sus políticas. `cuentas`, `movimientos`, `asignaciones_dinero` e `historial_asignaciones` tienen cero filas; `perfiles` tiene una. El trigger de creación de perfil en `auth.users` sigue activo.
- Auth tiene un usuario. Storage tiene cero buckets y cero objetos.
- El historial remoto de migraciones está vacío. `db push --dry-run --skip-vault` propone solo `20261104191448_finanzas_operaciones_seguras.sql`.
- El respaldo `supabase/backups/*20261104T185912Z*` cubre esquema y datos de `public` más la definición del trigger del perfil. Pasó SHA-256 y una restauración local aislada de `public`, pero **no** cubre los usuarios de Auth ni constituye una recuperación integral comprobada.

## Requisitos antes de aplicar

1. Confirmar que existe una vía de recuperación aceptable para Auth. Seguir `supabase/RECUPERACION_AUTH.md`: el volcado normal de Supabase CLI excluye `auth` y `storage`, y la prueba de restauración integral aún está pendiente. Exportar `auth.users` sin cifrado revelaría hashes, tokens y datos personales; un listado de usuarios o un volcado solo del esquema no sirve para recuperar cuentas. Una copia completa requiere un procedimiento privado, cifrado y probado en un entorno aislado, con las credenciales introducidas localmente, o una opción administrada de respaldo apropiada. No colocar secretos ni volcados en Git.
2. Tomar un **nuevo** respaldo de `public` justo antes de aplicar, en un directorio privado y excluido de Git; seguir `supabase/README.md`. Verificar SHA-256 y, si cambió el contenido, repetir la prueba de restauración local. Guardar una copia cifrada fuera del equipo.
3. Repetir las consultas de solo lectura: seis tablas y RLS; recuento de las cuatro tablas financieras (deben seguir vacías); trigger de perfil; historial de migraciones (debe seguir vacío); `db push --remote=ljfikbitkjpooskhfweu --dry-run --skip-vault` (debe enumerar solo esta migración). Si cambia cualquiera de estos supuestos, detener la aplicación y revisar el SQL.
4. Revisar el archivo SQL exacto y obtener aprobación explícita para aplicar **esa** versión al proyecto indicado. Evitar actividad financiera concurrente durante la aplicación.

## Aplicación, solo tras aprobación

Desde la raíz del repositorio:

```bash
npx --no-install supabase db push --remote=ljfikbitkjpooskhfweu --skip-vault
```

No usar `--yes`, `migration repair` ni `db reset`. Tras ejecutar, consultar el historial remoto; comprobar seis tablas y RLS, los nuevos objetos y sus permisos, el trigger de Auth y la compilación de React. Hacer una prueba funcional con una cuenta de prueba y montos ficticios solamente cuando se autorice crear esos datos remotos.

## Ante un fallo

- Detener escrituras de la app y conservar el error y el estado de la base. Consultar historial y objetos antes de reintentar; no marcar manualmente la migración como aplicada.
- Si la migración no llegó a aplicarse, investigar la causa y preparar una corrección versionada. No ejecutar un SQL inverso improvisado sobre datos financieros.
- Si ya hubo operaciones de usuarios, una restauración del respaldo previo perdería los cambios posteriores; primero evaluar un arreglo incremental o una exportación adicional de los datos actuales. Restaurar `public` sobre una base nueva sin Auth deja `perfiles` sin sus usuarios asociados.
- Una recuperación integral exige restaurar y verificar también Auth. El respaldo actual solo permite recuperar `public` en un entorno aislado y el trigger, con la limitación documentada en `supabase/README.md`. Storage no tenía objetos en la comprobación, pero volver a consultar antes de aplicar.

No se ha probado una restauración integral ni se ha aplicado la migración remota.

## Segunda migración (2026-11-16): categorías, fechas y anulación

`20261116170000_finanzas_categorias_fechas_anulacion.sql` se aplica **junto con** la primera (el mismo `db push` envía ambas, en orden). Añade:

- `grant select` explícito a `authenticated` sobre `cuentas`, `categorias`, `movimientos`, `asignaciones_dinero` e `historial_asignaciones`. El volcado remoto del 2026-11-04 muestra que ese rol **no** tenía `SELECT` en esas tablas; sin este permiso la pantalla de Finanzas falla al cargar aunque RLS esté bien. RLS sigue limitando cada fila a su dueño.
- Categorías solo por RPC: `finanzas_crear_categoria`, `finanzas_desactivar_categoria` (conserva el historial) y `finanzas_crear_categorias_sugeridas` (Trabajo, Padres, Ventas, Otros ingresos, Comida, Transporte, Estudios, Personal, Otros gastos).
- Fecha elegible (`p_fecha date`, hora de Lima, nunca futura) en `finanzas_registrar_movimiento` y `finanzas_transferir`. Las firmas anteriores se reemplazan.
- `finanzas_anular_movimiento`: marca `anulado_at`/`anulado_motivo` sin borrar filas, revierte cuenta y destino, anula ambos lados de una transferencia y rechaza anulaciones que dejarían saldos negativos. El saldo inicial no se anula.

Verificado el 2026-11-16 en un Postgres desechable (PGlite) cargado con el volcado de `public` y una simulación mínima de `auth`: ambas migraciones se aplican, `tests/finanzas.sql` y `tests/finanzas_categorias_fechas_anulacion.sql` pasan, y `anon` no puede leer tablas ni invocar las RPC. Conviene repetir ambas pruebas en Supabase local antes del despliegue.
