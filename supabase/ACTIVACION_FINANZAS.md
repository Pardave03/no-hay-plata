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
