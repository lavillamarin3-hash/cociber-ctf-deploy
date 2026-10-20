#!/usr/bin/env bash
# Configura solo un cluster 16/main ya creado en el disco de datos.
# No instala paquetes, crea roles, lee contraseñas, reinicia ni mueve datos.
set -Eeuo pipefail
set +x
umask 077

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
usage() {
    printf '%s\n' \
      'Uso: sudo bash scripts/configure-postgresql.sh [--check|--apply] [--app-ip 10.10.10.13] [--memory-guard]' \
      'Sin --apply solo valida. --apply respalda configuración y prepara cambios; NO reinicia.' \
      '--memory-guard instala el límite cgroup 20G/24G; revisa primero el presupuesto Redis/SO.'
}

MODE=check
APP_IP=10.10.10.13
MEMORY_GUARD=false
while (($#)); do
    case "$1" in
        --check) MODE=check; shift ;;
        --apply) MODE=apply; shift ;;
        --app-ip) (($# >= 2)) || die 'Falta el valor de --app-ip.'; APP_IP=$2; shift 2 ;;
        --memory-guard) MEMORY_GUARD=true; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die 'Opción desconocida. Usa --help.' ;;
    esac
done
[[ $EUID == 0 ]] || die 'Ejecuta con sudo para comprobar permisos de configuración.'
for program in python3 runuser findmnt mountpoint ip stat realpath install pg_lsclusters; do
    command -v "$program" >/dev/null || die "Falta el programa $program."
done
[[ -r /etc/os-release ]] || die 'No se encontró la identificación de Ubuntu.'
# Archivo del sistema; nunca se carga un archivo de secretos como código.
. /etc/os-release
[[ ${ID:-} == ubuntu && ${VERSION_ID:-} == 26.04 ]] || die 'Este procedimiento requiere Ubuntu 26.04.'
python3 - "$APP_IP" <<'PY'
import ipaddress, sys
try:
    value = ipaddress.IPv4Address(sys.argv[1])
except ipaddress.AddressValueError:
    sys.exit('ERROR: APP_IP debe ser una IPv4 válida.')
network = ipaddress.IPv4Network('10.10.10.0/24')
if value not in network or value in (network.network_address, network.broadcast_address,
                                    ipaddress.IPv4Address('10.10.10.14')):
    sys.exit('ERROR: APP_IP debe identificar la VM de aplicación dentro de 10.10.10.0/24.')
PY
ip -j -4 address show | python3 -c 'import json,sys; ips={v["local"] for i in json.load(sys.stdin) for v in i.get("addr_info",[])}; sys.exit(0 if "10.10.10.14" in ips else 1)' \
    || die 'La IP 10.10.10.14 todavía no está asignada a esta VM.'
mountpoint -q /mnt/db_data || die '/mnt/db_data debe ser un disco de datos ya montado; no usar el disco SO.'
[[ $(findmnt -n -o TARGET --target /mnt/db_data) == /mnt/db_data ]] \
    || die 'El montaje de datos no corresponde a /mnt/db_data.'

DATA_DIR=/mnt/db_data/postgres
MAIN_CONF=/etc/postgresql/16/main/postgresql.conf
HBA=/etc/postgresql/16/main/pg_hba.conf
CONF_DIR=/etc/postgresql/16/main/conf.d
DEST_CONF=$CONF_DIR/99-cociber.conf
GUARD_DIR=/etc/systemd/system/postgresql@16-main.service.d
GUARD=$GUARD_DIR/20-memory-guard.conf
MOUNT_GUARD=$GUARD_DIR/10-data-mount.conf
ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
SOURCE_DIR=$ROOT_DIR/configs/postgresql
POSTGRES=/usr/lib/postgresql/16/bin/postgres
MARKER=COCIBER_POSTGRESQL_16_MANAGED_V1

[[ -x $POSTGRES && -r $MAIN_CONF && -r $HBA ]] || die 'Falta PostgreSQL 16/main. Crea un cluster nuevo según la guía; no reutilices otro automáticamente.'
[[ -d $DATA_DIR && ! -L $DATA_DIR ]] || die 'El directorio de datos no existe o es un enlace; no se moverán datos.'
[[ $(realpath -- "$DATA_DIR") == "$DATA_DIR" ]] || die 'La ruta de datos contiene un enlace inesperado.'
[[ -f $DATA_DIR/PG_VERSION && $(<"$DATA_DIR/PG_VERSION") == 16 ]] || die 'El directorio no contiene un cluster PostgreSQL 16.'
[[ $(stat -c %U "$DATA_DIR") == postgres && $(stat -c %a "$DATA_DIR") == 700 ]] \
    || die 'El directorio de datos debe pertenecer a postgres y tener permisos 0700.'
for path in "$MAIN_CONF" "$HBA"; do
    [[ -f $path && ! -L $path ]] || die 'La configuración debe ser un archivo regular, sin enlaces.'
done
CURRENT_DATA=$(runuser -u postgres -- "$POSTGRES" -D "$DATA_DIR" -c "config_file=$MAIN_CONF" -C data_directory)
[[ $CURRENT_DATA == "$DATA_DIR" ]] || die 'El cluster apunta a otro directorio. Migra y respalda los datos antes; este script no los mueve.'
grep -Eq "^[[:space:]]*include_dir[[:space:]]*=[[:space:]]*'conf.d'" "$MAIN_CONF" \
    || die "Activa include_dir = 'conf.d' según la guía antes de continuar."
for file in 99-cociber.conf pg_hba.conf.template 20-memory-guard.conf 10-data-mount.conf; do
    [[ -f $SOURCE_DIR/$file && ! -L $SOURCE_DIR/$file ]] || die 'Falta una plantilla regular de PostgreSQL.'
done
for dir in "$CONF_DIR" "$GUARD_DIR"; do
    [[ ! -L $dir ]] || die 'No se modificará un directorio de configuración enlazado.'
done
for path in "$DEST_CONF" "$GUARD" "$MOUNT_GUARD"; do
    if [[ -e $path || -L $path ]]; then
        [[ -f $path && ! -L $path ]] || die 'No se sobrescribirá una configuración enlazada.'
        grep -qxF "# $MARKER" "$path" || die 'Hay una configuración ajena con el mismo nombre; revísala manualmente.'
    fi
done
[[ -r /sys/fs/cgroup/cgroup.controllers || $MEMORY_GUARD == false ]] \
    || die 'El límite de memoria requiere cgroup v2.'
runuser -u postgres -- test -r /etc/ssl/certs/ssl-cert-snakeoil.pem \
    || die 'Falta el certificado TLS inicial del paquete ssl-cert.'
runuser -u postgres -- test -r /etc/ssl/private/ssl-cert-snakeoil.key \
    || die 'Postgres no puede leer la clave TLS inicial; revisa el grupo ssl-cert.'

printf 'Validado: PostgreSQL 16/main, datos %s, APP %s/32.\n' "$DATA_DIR" "$APP_IP"
if [[ $MODE == check ]]; then
    printf 'Solo comprobación. No se modificaron archivos ni servicios.\n'
    exit 0
fi

BACKUP=/var/backups/cociber-ctf/pg-config-$(date -u +%Y%m%dT%H%M%SZ)-$$
install -d -o root -g root -m 0700 "$BACKUP"
cp -a -- "$MAIN_CONF" "$BACKUP/postgresql.conf"
cp -a -- "$HBA" "$BACKUP/pg_hba.conf"
[[ ! -e $DEST_CONF ]] || cp -a -- "$DEST_CONF" "$BACKUP/99-cociber.conf"
[[ ! -e $GUARD ]] || cp -a -- "$GUARD" "$BACKUP/20-memory-guard.conf"
[[ ! -e $MOUNT_GUARD ]] || cp -a -- "$MOUNT_GUARD" "$BACKUP/10-data-mount.conf"
TEMP_DIR=$(mktemp -d)
trap 'rm -f -- "$TEMP_DIR/pg_hba.conf"; rmdir -- "$TEMP_DIR"' EXIT
python3 - "$SOURCE_DIR/pg_hba.conf.template" "$TEMP_DIR/pg_hba.conf" "$APP_IP" <<'PY'
from pathlib import Path
import sys
source = Path(sys.argv[1]).read_text()
Path(sys.argv[2]).write_text(source.replace('@APP_IP@', sys.argv[3]))
PY
install -d -o postgres -g postgres -m 0755 "$CONF_DIR"
install -o postgres -g postgres -m 0644 "$SOURCE_DIR/99-cociber.conf" "$DEST_CONF"
install -o postgres -g postgres -m 0640 "$TEMP_DIR/pg_hba.conf" "$HBA"
if ! runuser -u postgres -- "$POSTGRES" -D "$DATA_DIR" -c "config_file=$MAIN_CONF" -C shared_buffers >/dev/null; then
    cp -a -- "$BACKUP/pg_hba.conf" "$HBA"
    if [[ -e $BACKUP/99-cociber.conf ]]; then
        cp -a -- "$BACKUP/99-cociber.conf" "$DEST_CONF"
    else
        rm -f -- "$DEST_CONF"
    fi
    die 'No se pudo leer la configuración. Se restauraron los archivos anteriores; no se reinició el servicio.'
fi
install -d -o root -g root -m 0755 "$GUARD_DIR"
install -o root -g root -m 0644 "$SOURCE_DIR/10-data-mount.conf" "$MOUNT_GUARD"
if [[ $MEMORY_GUARD == true ]]; then
    install -o root -g root -m 0644 "$SOURCE_DIR/20-memory-guard.conf" "$GUARD"
fi
printf 'Configuración preparada. Respaldo: %s\n' "$BACKUP"
printf 'No se reinició PostgreSQL. Revisa la guía para validar HBA, recargar systemd y arrancar en ventana de mantenimiento.\n'
