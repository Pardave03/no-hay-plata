#!/usr/bin/env bash
set -euo pipefail
umask 077

# Uso: PGHOST=... PGPORT=... PGUSER=... PGDATABASE=... \
#      GPG_RECIPIENT=<huella-verificada> ./backup_auth_encrypted.sh
# La contraseña de PostgreSQL se solicita por libpq en la terminal.

: "${PGHOST:?Falta PGHOST}"
: "${PGPORT:?Falta PGPORT}"
: "${PGUSER:?Falta PGUSER}"
: "${PGDATABASE:?Falta PGDATABASE}"
: "${GPG_RECIPIENT:?Falta GPG_RECIPIENT}"
: "${PGSSLMODE:?Falta PGSSLMODE (require, verify-ca o verify-full)}"
case "$PGSSLMODE" in
  require|verify-ca|verify-full) ;;
  *) echo 'PGSSLMODE debe exigir TLS' >&2; exit 1 ;;
esac
if [[ ! "$GPG_RECIPIENT" =~ ^[[:xdigit:]]{40}$ ]]; then
  echo 'GPG_RECIPIENT debe ser la huella completa de 40 caracteres' >&2
  exit 1
fi
if ! gpg --batch --list-secret-keys "$GPG_RECIPIENT" >/dev/null 2>&1; then
  echo 'No está disponible la clave privada GPG para comprobar el respaldo' >&2
  exit 1
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
backup_dir="${AUTH_BACKUP_DIR:-$repo_root/supabase/backups}"
mkdir -p "$backup_dir"
chmod 700 "$backup_dir"

stamp="$(date -u +%Y%m%dT%H%M%SZ)"
output="$backup_dir/auth_data_${stamp}.dump.gpg"
partial="${output}.partial"

if [[ -e "$output" || -e "$partial" ]]; then
  echo 'Ya existe un archivo con esta marca de tiempo' >&2
  exit 1
fi

cleanup() { rm -f -- "$partial"; }
trap cleanup EXIT

# Archivo custom de pg_dump: conserva valores UUID y todas las tablas de auth.
# Solo el flujo cifrado llega al disco. No ejecutar con trazas de shell (set -x).
command -v pg_dump >/dev/null || { echo 'Falta pg_dump (instala postgresql-client compatible con el servidor)' >&2; exit 1; }
echo "Conectando a $PGHOST:$PGPORT como $PGUSER (base $PGDATABASE)..." >&2
pg_dump --host="$PGHOST" --port="$PGPORT" --username="$PGUSER" --dbname="$PGDATABASE" \
  --password --format=custom --data-only --schema=auth --no-owner --no-privileges \
  | gpg --batch --yes --encrypt --recipient "$GPG_RECIPIENT" --output "$partial"

test -s "$partial"
mv -- "$partial" "$output"
sha256sum "$output" > "${output}.sha256"
chmod 600 "$output" "${output}.sha256"
trap - EXIT
echo "Respaldo cifrado creado: $output"
