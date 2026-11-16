# Respaldo y recuperación de Supabase Auth

Proyecto: `ljfikbitkjpooskhfweu` (plan Free). Este procedimiento no ejecuta ninguna operación remota por sí mismo. **No exportar Auth remoto sin autorización explícita.**

## Alcance y método

Supabase Free no incluye copias diarias administradas. El volcado ordinario de la CLI excluye por defecto los esquemas administrados `auth` y `storage`. La documentación oficial de migración de usuarios admite una exportación/importación SQL de las tablas de `auth`, incluidos los hashes de contraseña. Por eso se propone `pg_dump` directo de **todos los datos del esquema `auth`** en formato custom, cifrado en streaming con GnuPG, junto con los respaldos existentes de `public` y del trigger de perfil.

El archivo cifrado contiene identificadores UUID, usuarios, identidades, hashes y posiblemente sesiones o tokens. **Tratarlo como material altamente sensible incluso cifrado.** No lo enviar por chat, correo ni subirlo a Git. La contraseña de PostgreSQL, la clave privada GPG y los secretos del proyecto tampoco deben entrar en Git. El respaldo no incluye configuración de Auth del panel, claves JWT, claves de API, plantillas de correo, proveedores externos ni objetos de Storage.

Conservar los UUID en un volcado SQL permite que `public.perfiles.usuario_id` siga apuntando a los usuarios restaurados. Los hashes de contraseñas pueden permitir que vuelvan a iniciar sesión con la misma contraseña si el esquema y la versión de Auth de destino son compatibles; **esto debe comprobarse con una restauración real**. En otro proyecto, los tokens y sesiones anteriores pueden no ser válidos por la diferencia de claves JWT; planificar un nuevo inicio de sesión. No copiar el secreto JWT de producción para una prueba local.

## Preparación de claves y acceso

1. Crear o elegir en el equipo una clave GPG destinada a respaldos. Verificar personalmente su **huella completa** de 40 caracteres con `gpg --fingerprint`. Guardar una copia de la clave privada y su frase de paso en un lugar seguro, separado del respaldo cifrado. Probar que puede descifrarse antes de depender de ella. No usar un identificador corto de clave.
2. Obtener en **Dashboard → Connect** el host, puerto, usuario y nombre de la base. Si la conexión directa no funciona por IPv6, usar el *session pooler* que indica Supabase. Introducir la contraseña de PostgreSQL únicamente cuando `pg_dump` la solicite en la terminal. No ponerla en URL, argumentos, archivos versionados ni en el chat. La sesión de CLI por sí sola no da a `pg_dump` la contraseña de PostgreSQL.
3. Desde la raíz del repositorio, asignar en la terminal `PGHOST`, `PGPORT`, `PGUSER`, `PGDATABASE`, `PGSSLMODE` y `GPG_RECIPIENT` (huella completa). Usar `PGSSLMODE=verify-full` con el certificado raíz configurado cuando esté disponible; el mínimo admitido por el script es `require`, que cifra la conexión pero no verifica por completo la identidad del servidor. Estas variables no contienen secretos. Ejecutar `bash supabase/scripts/backup_auth_encrypted.sh`; `pg_dump --password` solicitará la contraseña en la terminal. El archivo resultante queda en `supabase/backups/`, carpeta ignorada por Git y con permisos privados. No ejecutar con `set -x`.
4. Verificar `sha256sum -c` del archivo `.sha256`. Activar `set -o pipefail` en la terminal y descifrarlo **solo en memoria** para listar el índice del archivo: `gpg --decrypt RUTA_DEL_ARCHIVO.dump.gpg | pg_restore --list >/dev/null`. Comprobar que el comando termina sin error. Guardar otra copia cifrada fuera del equipo; verificar su hash y capacidad de descifrado. El hash comprueba integridad de bytes, no garantiza restaurabilidad.

El script falla si `pg_dump` o GPG falla, elimina el archivo parcial y no conserva texto SQL sin cifrar. Requiere PostgreSQL `pg_dump` compatible con la versión del servidor, GnuPG y una clave pública disponible. El nombre de archivo y los mensajes de error pueden revelar metadatos de la operación, pero no deben mostrar filas del respaldo.

## Prueba de recuperación aislada

1. Arrancar una **instancia nueva y desechable** de Supabase local, sin conexión a producción. Restringir acceso al equipo y evitar que Auth local envíe correos externos. No usar el secreto JWT de producción.
2. Verificar la compatibilidad del esquema Auth local con el origen. Descifrar por tubería hacia `pg_restore` y restaurar datos de `auth` en la instancia limpia. Evitar restaurar sesiones y tokens activos al servir la instancia de prueba; la selección de tablas y el orden de restauración deben comprobarse en el ensayo, no improvisarse sobre producción.
3. Restaurar `public` y el trigger de perfil en un orden que conserve las referencias a `auth.users`. Verificar recuentos, UUID preservados, `auth.identities`, relaciones `perfiles → auth.users`, RLS y trigger. Probar inicio de sesión con una cuenta de prueba cuyo secreto se conozca por un canal privado; no imprimirla ni guardarla en el informe. Verificar también cierre y nuevo inicio de sesión.
4. Registrar cualquier incompatibilidad de esquema, extensión, clave de cifrado, proveedor externo o contraseña. Si falla, **no** considerar la recuperación verificada. El ensayo debe ser local: nunca ejecutar `pg_restore` contra `ljfikbitkjpooskhfweu`.

## Estado de verificación, 2026-11-04

El script se probó con una clave GPG temporal y datos Auth **ficticios** en la base local aislada. Se verificó SHA-256, descifrado, índice `pg_restore` con `users` e `identities`, y conservación del UUID ficticio. **No** se exportó Auth remoto; **no** se restauró el archivo cifrado en una instancia limpia ni se comprobó un inicio de sesión recuperado. Por tanto todavía no existe un respaldo completo y recuperable de Auth verificado.

Fuentes: [copias según plan](https://supabase.com/docs/guides/platform/backups), [comportamiento de `db dump`](https://supabase.com/docs/reference/cli/introduction), [migración de usuarios Auth](https://supabase.com/kb/troubleshooting/migrating-auth-users-between-projects), [migración con CLI](https://supabase.com/docs/guides/platform/migrating-within-supabase/backup-restore).
