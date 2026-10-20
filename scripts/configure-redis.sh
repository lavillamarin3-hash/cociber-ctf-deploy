#!/usr/bin/env bash
# Preparación nativa Ubuntu 26.04. Por defecto comprueba; --apply instala.
set +x
set -Eeuo pipefail
umask 077

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
DATA_PARENT=/mnt/db_data
DATA_DIR=/mnt/db_data/redis
CONFIG_DIR=/etc/cociber-redis
SECRETS_FILE=/etc/cociber-ctf/deploy-secrets.env
PREFIX=/opt/cociber-redis
SERVICE=cociber-redis.service
MODE="${1:---check}"
BUILD_DIR=

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
[[ "$MODE" == --check || "$MODE" == --apply ]] || fail 'Uso: sudo bash scripts/configure-redis.sh [--check|--apply]'
[[ $# -le 1 ]] || fail 'No se aceptan argumentos adicionales ni contraseñas por argumentos.'
[[ $EUID -eq 0 ]] || fail 'Ejecuta con sudo; el archivo de secretos solo es legible por root.'
[[ -r /etc/os-release ]] || fail 'Falta /etc/os-release.'
# shellcheck disable=SC1091
source /etc/os-release
[[ "${ID:-}" == ubuntu && "${VERSION_ID:-}" == 26.04 && "${VERSION_CODENAME:-}" == resolute ]] || fail 'Este procedimiento exige Ubuntu 26.04 resolute; no cambia de distribución.'
[[ -f "$ROOT_DIR/configs/redis/source.lock" && ! -L "$ROOT_DIR/configs/redis/source.lock" ]] || fail 'Falta el pin de versión fuente.'
# shellcheck disable=SC1091
source "$ROOT_DIR/configs/redis/source.lock"
[[ "$REDIS_VERSION" == 7.4.11 && "$REDIS_SHA256" == 3c266ece0abd54ed3b1c912c6eb86b7508cf382cb690ee6649d3843f018f6357 ]] || fail 'El pin fuente fue modificado; revisa versión y SHA256 antes de actualizar el script.'
[[ ! -L "$DATA_PARENT" && ! -L "$DATA_DIR" ]] || fail 'Los directorios de datos no pueden ser enlaces simbólicos.'
mountpoint -q "$DATA_PARENT" || fail 'Monta y verifica primero /mnt/db_data; no se escribirá en el disco raíz.'
[[ "$(findmnt -n -o TARGET -T "$DATA_PARENT")" == "$DATA_PARENT" ]] || fail 'El punto de montaje real debe ser /mnt/db_data.'
[[ "$(realpath -m -- "$DATA_DIR")" == "$DATA_DIR" ]] || fail 'La ruta de Redis sale del destino esperado.'
if [[ -e "$DATA_DIR" ]]; then
  [[ -d "$DATA_DIR" && "$(stat -c %d "$DATA_DIR")" == "$(stat -c %d "$DATA_PARENT")" ]] || fail 'Redis debe ser un subdirectorio del mismo filesystem de /mnt/db_data.'
fi
ip -4 -o address show | grep -Eq '[[:space:]]10\.10\.10\.14/' || fail 'La VM no tiene la IP esperada 10.10.10.14.'
[[ -f "$SECRETS_FILE" && ! -L "$SECRETS_FILE" ]] || fail 'Prepara /etc/cociber-ctf/deploy-secrets.env siguiendo la guía privada.'
[[ "$(stat -c %u "$SECRETS_FILE")" == 0 ]] || fail 'El archivo de secretos debe pertenecer a root.'
secrets_mode="$(stat -c %a "$SECRETS_FILE")"
(( (8#$secrets_mode & 077) == 0 )) || fail 'El archivo de secretos no puede tener permisos de grupo ni de otros (usa 0600).'
[[ "$(stat -c %u /etc/cociber-ctf)" == 0 ]] || fail 'El directorio de secretos debe pertenecer a root.'
secrets_dir_mode="$(stat -c %a /etc/cociber-ctf)"
(( (8#$secrets_dir_mode & 022) == 0 )) || fail 'El directorio de secretos no puede permitir escritura a grupo/otros.'
# Validar como datos antes de cargar la configuración privada de confianza.
# Rechaza también los marcadores públicos de .env.example, sin mostrarlos.
python3 - "$ROOT_DIR/tools" "$SECRETS_FILE" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
from private_env import read_private_env
try:
    read_private_env(sys.argv[2])
except ValueError as error:
    sys.exit(str(error))
PY
# Archivo Bash de confianza, creado por root; nunca se muestra su contenido.
# shellcheck disable=SC1091
source "$SECRETS_FILE"
[[ -n "${REDIS_ADMIN_PASSWORD:-}" ]] || fail 'Falta REDIS_ADMIN_PASSWORD en el archivo de secretos.'

printf 'SO correcto; montaje e IP correctos; secreto presente sin mostrarlo.\n'
printf 'Versión fijada: Redis %s; datos: %s\n' "$REDIS_VERSION" "$DATA_DIR"
df -h -- "$DATA_PARENT"
if [[ "$MODE" == --check ]]; then
  if [[ -x "$PREFIX/current/bin/redis-server" ]]; then "$PREFIX/current/bin/redis-server" --version; fi
  printf 'Comprobación terminada. No se instalaron paquetes ni se cambió el servicio.\n'
  exit 0
fi

# No se detienen ni sustituyen servicios Redis preexistentes automáticamente.
for legacy_service in redis-server.service redis.service; do
  if systemctl is-active --quiet "$legacy_service"; then fail "Hay un servicio activo $legacy_service; planifica su migración y respaldo primero."; fi
done
if [[ -d "$DATA_DIR" && ! -f /etc/systemd/system/cociber-redis.service ]]; then
  [[ -z "$(find "$DATA_DIR" -mindepth 1 -maxdepth 1 -print -quit)" ]] || fail 'El destino ya contiene datos sin servicio administrado; no se abrirán ni sobrescribirán automáticamente.'
fi
[[ ! -L "$CONFIG_DIR" && ! -L "$PREFIX" ]] || fail 'El prefijo o directorio de configuración no pueden ser symlinks.'
[[ ! -L "$PREFIX/$REDIS_VERSION" && ! -L "$PREFIX/$REDIS_VERSION/bin" && ! -L /etc/systemd/system/cociber-redis.service ]] || fail 'La versión y unidad administradas no pueden ser enlaces simbólicos.'
for managed_file in redis.conf users.acl; do
  [[ ! -L "$CONFIG_DIR/$managed_file" ]] || fail "La configuración $managed_file no puede ser un enlace simbólico."
done
[[ ! -e "$PREFIX/current" || -L "$PREFIX/current" ]] || fail 'El enlace current no puede reemplazar un directorio existente.'
if [[ -L "$PREFIX/current" ]]; then
  [[ "$(realpath -- "$PREFIX/current")" == "$PREFIX/"* ]] || fail 'El enlace current apunta fuera del prefijo administrado.'
fi

apt-get update
apt-get install -y --no-install-recommends build-essential libssl-dev pkg-config tcl ca-certificates curl
getent group redis >/dev/null || groupadd --system redis
id -u redis >/dev/null 2>&1 || useradd --system --gid redis --home-dir /nonexistent --no-create-home --shell /usr/sbin/nologin redis
install -d -o root -g root -m 0755 "$PREFIX"
install -d -o root -g redis -m 0750 "$CONFIG_DIR"
install -d -o redis -g redis -m 0750 "$DATA_DIR"
runuser -u redis -- test -x "$DATA_PARENT" || fail 'El usuario redis no puede atravesar /mnt/db_data. Ajusta solo la ruta padre según la guía de almacenamiento.'

backup_dir="/var/backups/cociber-redis/config-$(date -u +%Y%m%dT%H%M%S)-$$"
install -d -o root -g root -m 0700 "$backup_dir"
for previous_file in redis.conf users.acl; do
  if [[ -f "$CONFIG_DIR/$previous_file" ]]; then cp -a -- "$CONFIG_DIR/$previous_file" "$backup_dir/$previous_file"; fi
done
if [[ -f /etc/systemd/system/cociber-redis.service ]]; then cp -a /etc/systemd/system/cociber-redis.service "$backup_dir/cociber-redis.service"; fi
if [[ -L "$PREFIX/current" ]]; then readlink -- "$PREFIX/current" > "$backup_dir/previous-prefix.txt"; fi

cleanup_build() {
  if [[ -n "$BUILD_DIR" && "$BUILD_DIR" == /var/tmp/cociber-redis-build.* && -d "$BUILD_DIR" && ! -L "$BUILD_DIR" ]]; then rm -rf -- "$BUILD_DIR"; fi
}
trap cleanup_build EXIT
if [[ ! -x "$PREFIX/$REDIS_VERSION/bin/redis-server" ]]; then
  BUILD_DIR="$(mktemp -d /var/tmp/cociber-redis-build.XXXXXXXX)"
  chmod 0755 "$BUILD_DIR"
  archive="$BUILD_DIR/redis-$REDIS_VERSION.tar.gz"
  curl --fail --show-error --silent --location --proto '=https' --tlsv1.2 --output "$archive" "https://download.redis.io/releases/redis-$REDIS_VERSION.tar.gz"
  printf '%s  %s\n' "$REDIS_SHA256" "$archive" | sha256sum --check --status || fail 'SHA256 incorrecto: no se extraerá ni compilará el archivo.'
  tar -xzf "$archive" -C "$BUILD_DIR" --no-same-owner
  source_dir="$BUILD_DIR/redis-$REDIS_VERSION"
  chown -R redis:redis "$source_dir"
  runuser -u redis -- make -C "$source_dir" -j2 BUILD_TLS=yes
  runuser -u redis -- make -C "$source_dir" test
  install -d -o root -g root -m 0755 "$PREFIX/$REDIS_VERSION/bin"
  for binary in redis-server redis-cli redis-check-rdb redis-check-aof; do
    install -o root -g root -m 0755 "$source_dir/src/$binary" "$PREFIX/$REDIS_VERSION/bin/$binary"
  done
  install -o root -g root -m 0644 "$ROOT_DIR/configs/redis/source.lock" "$PREFIX/$REDIS_VERSION/source.lock"
fi
"$PREFIX/$REDIS_VERSION/bin/redis-server" --version | grep -Eq 'v=7\.4\.11([[:space:]]|$)' || fail 'El binario instalado no coincide con Redis 7.4.11.'

# Un único fichero ACL generado, con hash SHA256 y sin contraseña en argumentos.
admin_hash="$(printf %s "$REDIS_ADMIN_PASSWORD" | sha256sum | awk '{print $1}')"
acl_temp="$(mktemp "$CONFIG_DIR/.users.acl.XXXXXXXX")"
printf 'user default off resetpass resetchannels -@all\nuser cociberctf on #%s ~* &* +@all\n' "$admin_hash" > "$acl_temp"
if [[ -n "${REDIS_APP_PASSWORD:-}" ]]; then
  app_hash="$(printf %s "$REDIS_APP_PASSWORD" | sha256sum | awk '{print $1}')"
  printf 'user cociber_app on #%s ~* &ctf:* +@read +@write +@connection +@pubsub +@scripting -@admin -@dangerous\n' "$app_hash" >> "$acl_temp"
  unset app_hash
fi
chown root:redis "$acl_temp"
chmod 0640 "$acl_temp"
mv -T -- "$acl_temp" "$CONFIG_DIR/users.acl"
unset admin_hash
install -o root -g redis -m 0640 "$ROOT_DIR/configs/redis/redis.conf" "$CONFIG_DIR/redis.conf"
install -o root -g root -m 0644 "$ROOT_DIR/configs/redis/cociber-redis.service" /etc/systemd/system/cociber-redis.service
ln -sfn -- "$PREFIX/$REDIS_VERSION" "$PREFIX/current"
systemd-analyze verify /etc/systemd/system/cociber-redis.service
systemctl daemon-reload
systemctl enable "$SERVICE"
systemctl restart "$SERVICE"
redis_cli="$PREFIX/current/bin/redis-cli"
redis_admin() { REDISCLI_AUTH="$REDIS_ADMIN_PASSWORD" "$redis_cli" --user cociberctf -h 127.0.0.1 -p 6379 --raw "$@"; }
ready=0
for attempt in $(seq 1 30); do
  if [[ "$(redis_admin PING 2>/dev/null || true)" == PONG ]]; then ready=1; break; fi
  sleep 1
done
[[ "$ready" == 1 ]] || fail 'Redis no respondió PONG autenticado. Revisa journalctl -u cociber-redis; no publiques secretos.'
unauthenticated="$(env -u REDISCLI_AUTH "$redis_cli" -h 127.0.0.1 -p 6379 --raw PING 2>&1 || true)"
[[ "$unauthenticated" == *NOAUTH* ]] || fail 'La prueba sin credenciales no fue rechazada como se esperaba.'
[[ "$(redis_admin ACL WHOAMI)" == cociberctf ]] || fail 'Usuario autenticado inesperado.'
if [[ -n "${REDIS_APP_PASSWORD:-}" ]]; then
  [[ "$(REDISCLI_AUTH="$REDIS_APP_PASSWORD" "$redis_cli" --user cociber_app -h 127.0.0.1 -p 6379 --raw PING)" == PONG ]] || fail 'La cuenta separada de aplicación no respondió PONG.'
fi
redis_admin INFO server | grep -q '^redis_version:7\.4\.11' || fail 'La versión del proceso activo no coincide.'
printf 'PONG autenticado correcto; acceso anónimo rechazado; versión 7.4.11 confirmada.\n'
redis_admin CONFIG GET maxmemory maxmemory-policy dir appendonly
unset REDIS_ADMIN_PASSWORD REDIS_APP_PASSWORD REDISCLI_AUTH
printf 'Respaldo de configuración previo: %s\n' "$backup_dir"
printf 'Configura el firewall para permitir 6379 únicamente desde 10.10.10.13/32; el script no altera reglas de red.\n'
