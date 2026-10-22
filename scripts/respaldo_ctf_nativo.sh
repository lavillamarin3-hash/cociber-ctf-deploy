#!/usr/bin/env bash
# Respaldo de PostgreSQL 16 y Redis 7 NATIVOS en LAB-DB-POSTGRES (10.10.10.14).
# No restaura, elimina ni modifica las tablas existentes.
# Uso: sudo bash scripts/respaldo_ctf_nativo.sh /RUTA/EXTERNA/EXISTENTE
set -Eeuo pipefail
umask 077

DB_NAME="${DB_NAME:-cociber_ctf}"
REDIS_HOST="${REDIS_HOST:-127.0.0.1}"
REDIS_PORT="${REDIS_PORT:-6379}"
REDIS_USER="${REDIS_USER:-cociberctf}"
DESTINO="${1:-}"

if (( EUID != 0 )); then
  echo "ERROR: utiliza sudo para respaldar PostgreSQL nativo." >&2
  exit 1
fi
if [[ -z "$DESTINO" || "$DESTINO" != /* || ! -d "$DESTINO" ]]; then
  echo "USO: sudo bash scripts/respaldo_ctf_nativo.sh /RUTA_ABSOLUTA_EXISTENTE" >&2
  exit 1
fi

for comando in sudo psql pg_dump pg_dumpall pg_restore sha256sum mktemp findmnt df; do
  command -v "$comando" >/dev/null || { echo "Falta la herramienta $comando" >&2; exit 1; }
done
REDIS_CLI="$(command -v redis-cli || true)"
REDIS_CHECK="$(command -v redis-check-rdb || true)"
if [[ -z "$REDIS_CLI" ]]; then REDIS_CLI=/opt/cociber-redis/current/bin/redis-cli; fi
if [[ -z "$REDIS_CHECK" ]]; then REDIS_CHECK=/opt/cociber-redis/current/bin/redis-check-rdb; fi
[[ -x "$REDIS_CLI" && -x "$REDIS_CHECK" ]] || {
  echo "No se encontraron redis-cli y redis-check-rdb de la instalación nativa." >&2
  exit 1
}

MONTAJE="$(findmnt -n -o TARGET -T "$DESTINO")"
df -h "$DESTINO"
if [[ "$MONTAJE" == "/" || "$MONTAJE" == "/mnt/db_data" ]]; then
  echo "AVISO: el destino está en $MONTAJE. Prefiere otro disco o almacenamiento externo." >&2
fi

MARCA="$(date -u +%Y%m%dT%H%M%SZ)"
CARPETA="$(mktemp -d "${DESTINO%/}/nativo_${MARCA}_XXXXXX")"
EXITO=0
fin() {
  unset REDISCLI_AUTH || true
  if (( EXITO == 0 )); then
    echo "RESPALDO INCOMPLETO: $CARPETA. NO uses esta carpeta como copia verificada." >&2
  fi
}
trap fin EXIT

sudo -u postgres psql -X -At -d "$DB_NAME" -c 'SELECT 1' >/dev/null
echo "1/4 Respaldando PostgreSQL: $DB_NAME"
sudo -u postgres pg_dump -Fc --no-owner --no-privileges -d "$DB_NAME" > "$CARPETA/postgres_ctf.dump"
[[ -s "$CARPETA/postgres_ctf.dump" ]] || { echo "Dump vacío." >&2; exit 1; }
pg_restore --list "$CARPETA/postgres_ctf.dump" >/dev/null

# Inventario sin hashes de contraseñas. Las credenciales privadas se guardan aparte.
sudo -u postgres pg_dumpall --roles-only --no-role-passwords > "$CARPETA/roles_sin_contrasenas.sql"

echo "2/4 Respaldando Redis ($REDIS_HOST:$REDIS_PORT)."
echo "Usuario ACL predeterminado: $REDIS_USER. Necesita permiso para SYNC/PSYNC."
if [[ -z "${REDISCLI_AUTH:-}" ]]; then
  if [[ ! -t 0 ]]; then
    echo "ERROR: requiere entrada interactiva para leer la contraseña de Redis." >&2
    exit 1
  fi
  read -r -s -p 'Contraseña de Redis (no se muestra): ' CLAVE
  printf '\n'
  [[ -n "$CLAVE" ]] || { echo "Contraseña vacía; se cancela por seguridad." >&2; exit 1; }
  export REDISCLI_AUTH="$CLAVE"
  unset CLAVE
fi
"$REDIS_CLI" --user "$REDIS_USER" -h "$REDIS_HOST" -p "$REDIS_PORT" --rdb "$CARPETA/redis_ctf.rdb"
[[ -s "$CARPETA/redis_ctf.rdb" ]] || { echo "RDB vacío." >&2; exit 1; }
"$REDIS_CHECK" "$CARPETA/redis_ctf.rdb" >/dev/null

echo "3/4 Generando comprobaciones de integridad."
(
  cd "$CARPETA"
  sha256sum postgres_ctf.dump redis_ctf.rdb roles_sin_contrasenas.sql > SHA256SUMS.txt
)
cat > "$CARPETA/LEEME.txt" <<EOF
Origen: LAB-DB-POSTGRES 10.10.10.14, PostgreSQL/Redis nativos
Fecha UTC: $MARCA
PostgreSQL: $DB_NAME
Redis: $REDIS_HOST:$REDIS_PORT (instantánea RDB de TODAS sus bases lógicas)
No incluye credenciales, ficheros .env, configuración de Apache Guacamole ni su base independiente.
PostgreSQL y Redis se copiaron en momentos distintos; no constituyen una transacción común.
No restaures estos ficheros en caliente sobre las bases productivas.
EOF

echo "4/4 Verificando huellas."
(cd "$CARPETA" && sha256sum -c SHA256SUMS.txt)
EXITO=1
echo "RESPALDO COMPLETO: $CARPETA"
echo "IMPORTANTE: transfiere esta carpeta a almacenamiento externo protegido."
