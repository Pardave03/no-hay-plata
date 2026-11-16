# Migraciones de No Hay Plata

Proyecto remoto: `ljfikbitkjpooskhfweu` (`No Hay Plata`). La CLI está fijada como dependencia de desarrollo; ejecútala con `npx --no-install supabase`. Usa siempre `--remote=ljfikbitkjpooskhfweu` para que el destino remoto sea explícito.

## Estado inicial (consulta de solo lectura, 2026-11-04)

En `public` existen `perfiles`, `cuentas`, `categorias`, `movimientos`, `asignaciones_dinero` e `historial_asignaciones`. Las seis tienen RLS activo. Se observaron políticas que restringen filas por `auth.uid()`, índices y claves foráneas, y el trigger `auth.users → crear_perfil_usuario()`. El historial remoto de migraciones está vacío. Esta descripción **no es una copia de seguridad** y puede quedar desactualizada.

No se creó una migración inicial con las tablas existentes: aplicarla con `db push` intentaría crearlas otra vez. Tampoco se marcó ninguna migración como aplicada. Los próximos cambios se guardarán en archivos SQL con fecha dentro de `migrations/` y solo se aplicarán tras revisión y aprobación expresa.

## Autenticación de la CLI

Ejecuta `npx --no-install supabase login` en tu terminal. Sigue el flujo de Supabase; la credencial de la CLI debe quedar en el almacenamiento local del usuario, nunca en este repositorio ni en un chat. La clave publicable de Vite no concede acceso de administración a PostgreSQL. No hace falta ejecutar `supabase link`: el identificador se pasa explícitamente en cada comando remoto. El 2026-11-04 la CLI pudo listar el proyecto y consultar el historial remoto con ese identificador.

Comprueba el acceso con `npx --no-install supabase migration list --remote=ljfikbitkjpooskhfweu`. Este comando solo lee el historial. Si la CLI solicita acceso adicional a la base, complétalo en tu terminal o en el panel de Supabase; no añadas contraseñas a archivos versionados ni a la línea de comandos.

## Respaldo antes de cualquier migración remota

1. Comprueba en **Supabase Dashboard → Database → Backups** si hay una copia restaurable anterior al cambio, su fecha y el periodo de retención. Las copias administradas dependen del plan; no supongas que existen. Para una recuperación completa, esta es la opción preferida cuando está disponible.
2. Tras iniciar sesión en la CLI, exporta una copia lógica del esquema y los datos de `public` a una carpeta privada. Puede ser `supabase/backups/`, que está ignorada por Git, con permisos `700` para la carpeta y `600` para los archivos; es recomendable mover una copia cifrada fuera del equipo. Ejecuta `npx --no-install supabase db dump --remote=ljfikbitkjpooskhfweu --schema public --file /ruta/privada/esquema.sql` y luego `npx --no-install supabase db dump --remote=ljfikbitkjpooskhfweu --schema public --data-only --file /ruta/privada/datos.sql`. El segundo archivo contiene datos personales: protégelo y no lo subas a Git. Una exportación de `public` no equivale a una copia integral de Auth o Storage.
3. Verifica que ambos archivos existan, tengan contenido y calcula su SHA-256. La comprobación fuerte es restaurarlos en un **proyecto desechable distinto**, verificar tablas, RLS, funciones, triggers y recuentos, sin tocar el proyecto original. Si no se puede hacer esa prueba, registra que la restauración aún no está verificada. El dump de `public` incluye la función `crear_perfil_usuario()` pero no el trigger sobre `auth.users`; registra su definición por separado. Los datos de `public.perfiles` dependen de los IDs de `auth.users`, que no están en este dump. Para una recuperación completa usa una copia integral de Supabase o restituye Auth antes de cargar esos datos.

### Exportación realizada el 2026-11-04

En `supabase/backups/` se guardaron `schema_public_20261104T185912Z.sql`, `data_public_20261104T185912Z.sql`, `auth_profile_trigger_20261104T185912Z.sql` y `SHA256SUMS_20261104T185912Z.txt`. Todos están ignorados por Git y restringidos al usuario local. Los tres archivos pasan `sha256sum -c`.

Se probó la restauración en una pila **local aislada** (`/tmp/no-hay-plata-restore-test`): seis tablas, seis con RLS, 19 políticas y el trigger de `auth.users`. El dump de datos cargó un perfil, pero dejó una referencia huérfana porque no incluye `auth.users`; para completar la prueba local se insertó un usuario **ficticio** con el mismo ID y luego se verificó que no quedaran perfiles huérfanos. Esto confirma que el esquema y los datos de `public` son legibles y restaurables en ese entorno, pero **no verifica una recuperación integral de usuarios reales ni de Storage**. La exportación tampoco sustituye un respaldo físico o integral comprobado del proyecto.

No continúes con un cambio remoto hasta contar con un respaldo recuperable o un procedimiento de recuperación probado y aprobado.

## Flujo de cambios futuros

1. Consulta de nuevo el esquema y el historial remoto; revisa el SQL propuesto frente a las seis tablas existentes y sus políticas RLS.
2. Crea una migración nueva con `npx --no-install supabase migration new nombre_del_cambio` y edita su SQL. No incluyas credenciales ni datos de usuarios.
3. Revisa `npx --no-install supabase db push --remote=ljfikbitkjpooskhfweu --dry-run` y el plan de reversión. Comprueba que la copia de seguridad sigue siendo válida.
4. Solicita aprobación para el SQL concreto antes de ejecutar el `db push` real. No uses `--yes` ni `migration repair` para omitir revisiones o inventar historial.

Para adoptar las tablas existentes sin recrearlas, deja los dumps fuera de `migrations/` y empieza el historial versionado con el **primer cambio incremental real**. Antes de aplicarlo, inspecciona el estado remoto y confirma que el SQL solo altera los objetos previstos. Esto conserva las tablas actuales, pero no reconstruye el proyecto completo desde migraciones locales; una línea base reproducible requiere un diseño posterior y una prueba en un proyecto desechable.

No ejecutes `db reset --remote`, `db pull --remote` ni `migration repair` como parte de esta preparación. El primer `db pull` puede registrar una línea base como aplicada en el historial remoto; esa acción requiere un plan separado porque las tablas actuales se crearon fuera de migraciones.
