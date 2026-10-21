# Redis 7 nativo en lab-db-ctf

Destino: **Ubuntu Server 26.04 LTS, `resolute`, 10.10.10.14**, 4 vCPU y 32 GB de RAM compartidos con PostgreSQL. Aplicación autorizada: **10.10.10.13/32**. Redis usa TCP 6379 y `/mnt/db_data/redis`. No se utilizan contenedores.

El SO, el montaje ext4 en `/mnt/db_data` y las subcarpetas ya están creados en este servidor. Este capítulo continúa desde la instalación de Redis: comprueba el montaje, sin volver a formatear ni montar. No mueve datos de otro Redis ni cambia particiones. **150 GB es el objetivo de capacidad de Redis**, no una cuota creada por `mkdir`; una reserva exigible requiere las cuotas o volúmenes que se hayan definido en almacenamiento.

## 1. Comprobar Ubuntu y la disponibilidad real de Redis 7

En la VM de base de datos:

```bash
. /etc/os-release
printf 'Sistema: %s; versión: %s; serie: %s\n' "$ID" "$VERSION_ID" "$VERSION_CODENAME"
ip -4 address
findmnt --target /mnt/db_data
df -h /mnt/db_data
```

Debe aparecer Ubuntu `26.04`, `resolute` y `10.10.10.14`. No uses repositorios `noble` o `jammy` para resolver un paquete ausente en `resolute`.

La instalación APT oficial permite consultar y fijar una versión concreta; instalar `redis` sin versión seleccionaría la versión más reciente disponible. [Procedimiento APT oficial de Redis](https://redis.io/docs/latest/operate/oss_and_stack/install/install-stack/apt/).

Estos comandos agregan exclusivamente la serie correcta y **todavía no instalan Redis**:

```bash
sudo apt-get update
sudo apt-get install -y ca-certificates curl gnupg
curl --fail --silent --show-error --location https://packages.redis.io/gpg -o /tmp/cociber-redis-signing-key.asc
gpg --dearmor --batch --yes --output /tmp/cociber-redis-keyring.gpg /tmp/cociber-redis-signing-key.asc
sudo install -o root -g root -m 0644 /tmp/cociber-redis-keyring.gpg /usr/share/keyrings/cociber-redis-keyring.gpg
printf '%s\n' \
  'Types: deb' \
  'URIs: https://packages.redis.io/deb' \
  'Suites: resolute' \
  'Components: main' \
  'Signed-By: /usr/share/keyrings/cociber-redis-keyring.gpg' \
  | sudo tee /etc/apt/sources.list.d/cociber-redis.sources >/dev/null
sudo apt-get update
apt-cache madison redis-server
apt-cache madison redis-server | awk '$3 ~ /^([0-9]+:)?7\./ { print $3 }'
```

**Comprobación del 20 de octubre de 2026:** el [índice oficial `resolute` amd64](https://packages.redis.io/deb/dists/resolute/main/binary-amd64/Packages), con [Release fechado el 7 de octubre](https://packages.redis.io/deb/dists/resolute/Release), contiene versiones 8.8 y 8.10; no contiene Redis 7. Por eso esta entrega usa la ruta nativa desde fuente que sigue. Si el índice cambia, vuelve a revisar el resultado real de `madison`; no sustituyas automáticamente la ruta por una versión distinta ni por paquetes de otra distribución.

## 2. Versión y archivos de esta entrega

Se fija **Redis 7.4.11**, publicado el 17 de agosto de 2026. El instalador exige este pin, comprueba el tarball antes de extraerlo y verifica después la versión del proceso. [Notas oficiales de la versión](https://github.com/redis/redis/blob/7.4.11/00-RELEASENOTES).

```text
Origen: https://download.redis.io/releases/redis-7.4.11.tar.gz
SHA256: 3c266ece0abd54ed3b1c912c6eb86b7508cf382cb690ee6649d3843f018f6357
```

El SHA256 coincide con el registro de [tarballs oficiales de Redis](https://github.com/redis/redis-hashes/blob/master/README). También se descargó y calculó el hash del archivo para esta entrega. La compilación concreta en tu VM se realiza durante `--apply`; no se afirma que el servidor ya esté instalado.

| Archivo del repositorio | Destino o función |
|---|---|
| `configs/redis/source.lock` | Versión y SHA256 revisados |
| `configs/redis/redis.conf` | `/etc/cociber-redis/redis.conf` |
| `configs/redis/cociber-redis.service` | `/etc/systemd/system/cociber-redis.service` |
| `scripts/configure-redis.sh` | Preflight, compilación, configuración y comprobaciones |
| `configs/redis/apparmor.local.example` | Referencia para un perfil AppArmor existente |
| `configs/redis/memory-guardrail.example.conf` | Ejemplo **inactivo**, no se instala |

Los binarios quedan en `/opt/cociber-redis/7.4.11/bin`; `/opt/cociber-redis/current` apunta a esa versión. No se reemplazan `/usr/bin/redis-server` ni servicios de paquetes del sistema. La compilación se ejecuta como usuario `redis`, con TLS disponible y `make test`; la instalación final de binarios es propiedad de root. [Compilación oficial desde fuente](https://redis.io/docs/latest/operate/oss_and_stack/install/archive/install-redis/install-redis-from-source/).

## 3. Preparar los secretos y ejecutar

Antes de continuar, la guía privada debe haber creado `/etc/cociber-ctf/deploy-secrets.env`, propiedad de `root`, modo `0600`, con `REDIS_ADMIN_PASSWORD`. Para la cuenta de aplicación separada añade también `REDIS_APP_PASSWORD`, con un valor distinto. No copies una contraseña al repositorio, al comando de instalación ni a una URL. El script lee el fichero privado; no imprime su contenido.

Desde la raíz de este repositorio en Ubuntu:

```bash
sudo bash scripts/configure-redis.sh --check
sudo bash scripts/configure-redis.sh --apply
```

`--check` no instala paquetes ni modifica Redis. `--apply` compila, ejecuta las pruebas de Redis, genera el ACL y reinicia únicamente `cociber-redis.service`. Un Redis preexistente activo o datos de origen desconocido bloquean el procedimiento; planifica su migración por separado. Reaplicar cambia configuración y ACL: conserva previamente cualquier usuario de aplicación añadido manualmente, pues el archivo ACL administrado se genera de nuevo.

Los archivos de configuración anteriores se guardan en un directorio privado `/var/backups/cociber-redis/config-FECHA-PID`. **Ese respaldo es de configuración, no de datos.**

## 4. Acceso y permisos

Redis escucha exclusivamente en `127.0.0.1` y `10.10.10.14`, con `protected-mode yes`. La política de red debe permitir TCP 6379 desde `10.10.10.13/32` y rechazar el resto, además del acceso de administración local. No se expone al segmento de estudiantes ni a Internet. ACL y contraseña no cifran el tráfico; para atravesar redes no confiables configura TLS y su validación de certificados, o una conexión privada autenticada. [Modelo de seguridad oficial](https://redis.io/docs/latest/operate/oss_and_stack/management/security/).

El fichero `/etc/cociber-redis/users.acl` se genera con modo `0640`, propietario `root:redis`. Contiene `default` deshabilitado y el usuario **administrativo** solicitado `cociberctf`, con acceso `~* &* +@all`. La contraseña se transforma en hash SHA256 mediante una tubería; no se pasa como argumento. Esta cuenta puede modificar o borrar toda la información: resérvala para administración. [ACL y formato de contraseña hash](https://redis.io/docs/latest/operate/oss_and_stack/management/security/acl/).

Si existe `REDIS_APP_PASSWORD`, el instalador genera también **`cociber_app`** con este conjunto de permisos y el hash de su secreto separado:

```text
~* &ctf:* +@read +@write +@connection +@pubsub +@scripting -@admin -@dangerous
```

La cuenta de aplicación puede utilizar claves, seleccionar su base de datos, ejecutar scripts ordinarios `EVAL` y operar Pub/Sub en canales `ctf:*`. Se retiran las categorías administrativas y peligrosas, incluidas órdenes como `FLUSHALL`, `CONFIG` y `ACL`; `+@all` queda reservado a `cociberctf`. El patrón `~*` permite las claves de esta instancia dedicada y no constituye aislamiento entre aplicaciones. Si se comparte Redis con otros sistemas, primero inventaría y limita los prefijos reales. Las ACL se aplican también a los comandos que invoque un script: habilitar `EVAL` no permite ejecutar órdenes prohibidas en su interior. [Reglas de permisos de Redis](https://redis.io/docs/latest/commands/acl-setuser/).

La aceptación debe probar las operaciones reales de Cociber CTF, además de PONG: SET/GET, SELECT, EVAL y PUBLISH/SUBSCRIBE de `ctf:*`, y el rechazo de CONFIG/ACL/FLUSHALL. Si falta `REDIS_APP_PASSWORD`, el archivo contiene solo el administrador; prepara el secreto de aplicación antes de conectar la web. La URL privada de la aplicación debe usar `cociber_app`, nunca la cuenta administrativa. Los cambios persistentes del ACL se gestionan como root: el servicio no tiene permiso para sobrescribir sus archivos de configuración.

## 5. Comprobar PONG sin mostrar la contraseña

```bash
sudo systemctl status cociber-redis --no-pager
sudo ss -ltnp 'sport = :6379'
sudo journalctl -u cociber-redis -n 40 --no-pager
```

Para comprobar autenticación desde la misma VM, ejecuta el siguiente bloque.
Lee el archivo privado como datos con el mismo lector del instalador, sin
`source` ni `eval`. La contraseña viaja en `REDISCLI_AUTH`, no mediante `-a`,
argumentos o una URI. [Autenticación de `redis-cli`](https://redis.io/docs/latest/develop/tools/cli/).

```bash
sudo python3 - <<'PY'
import os
import subprocess
import sys
sys.path.insert(0, '/opt/cociber-ctf-deploy/tools')
from private_env import read_private_env

values = read_private_env('/etc/cociber-ctf/deploy-secrets.env')
cli = '/opt/cociber-redis/current/bin/redis-cli'
base_env = {'PATH': os.defpath, 'LANG': 'C.UTF-8'}
authenticated = {**base_env, 'REDISCLI_AUTH': values['REDIS_ADMIN_PASSWORD']}
checks = [
    ('127.0.0.1', ['PING']),
    ('10.10.10.14', ['ACL', 'WHOAMI']),
    ('127.0.0.1', ['INFO', 'server']),
    ('127.0.0.1', ['CONFIG', 'GET', 'maxmemory', 'maxmemory-policy', 'dir', 'appendonly']),
]
for host, command in checks:
    subprocess.run([cli, '--user', 'cociberctf', '-h', host, *command],
                   env=authenticated, check=True)
subprocess.run([cli, '-h', '127.0.0.1', 'PING'], env=base_env, check=True)
PY
```

Resultados: `PONG`, usuario `cociberctf`, versión `7.4.11`, `maxmemory` igual a `8589934592`, `noeviction`, ruta `/mnt/db_data/redis`, AOF `yes`. La última petición debe devolver **`NOAUTH Authentication required`**. No ejecutes `ACL LIST` para hacer una captura: mostraría hashes de las credenciales.

La prueba de conectividad remota se hace desde `10.10.10.13` con su cuenta de aplicación y su archivo privado; no distribuyas el secreto de administrador al servidor web para una comprobación rutinaria.

## 6. RAM: qué significa realmente el límite de 8 GB

`maxmemory 8gb` administra aproximadamente 8 GiB de memoria de Redis a efectos de la política del dataset. **No impone 8 GiB de RSS ni limita el total de padre e hijos**. Fragmentación, clientes y otras estructuras consumen memoria adicional. Durante persistencia y escritura intensa, el uso puede aproximarse al doble; mide la carga real. [Administración y memoria de Redis](https://redis.io/docs/latest/operate/oss_and_stack/management/admin/), [asignación y RSS](https://redis.io/docs/latest/operate/oss_and_stack/management/optimization/memory-optimization/).

`noeviction` se elige porque Redis guarda límites de intentos, autenticación y sesiones del terminal. Al llenarse, las operaciones que necesiten más memoria pueden devolver OOM en vez de expulsar claves de seguridad. Debes alertar y tratar esos errores; no conviertas silenciosamente la política en LRU. [Políticas de expulsión](https://redis.io/docs/latest/develop/reference/eviction/).

En esta VM compartida de 32 GB, un ejemplo de **presupuesto**, no una garantía, sería 8 GiB de `shared_buffers` de PostgreSQL + 8 GiB de Redis + 4 GiB para SO = 20 GiB: quedan 12 GiB para procesos PostgreSQL, conexiones, memoria de consultas y picos de persistencia. Si Redis sube cerca de 16 GiB durante un fork, quedarían solo 4 GiB de ese margen. Si PostgreSQL llega a usar 20 GiB reales y Redis 16 GiB, más 4 GiB de SO, el total sería 40 GiB: **no cabe**. `effective_cache_size` de PostgreSQL es una estimación del planificador, no una reserva de RAM; coordina los ajustes con el capítulo PostgreSQL.

No se instalan `MemoryHigh` ni `MemoryMax` por defecto. El ejemplo de drop-in está comentado porque esos límites abarcan el servicio y sus descendientes: un `MemoryMax=8G` puede terminar Redis al hacer persistencia, incluso aunque `maxmemory` sea 8 GiB. `MemoryHigh` aplica presión y `MemoryMax` puede provocar OOM en su cgroup. Elige valores solo tras medir PostgreSQL y Redis juntos. [Control de memoria de systemd](https://www.freedesktop.org/software/systemd/man/latest/systemd.resource-control.html).

```bash
free -h
sudo systemctl show cociber-redis -p MemoryCurrent -p MemoryPeak -p MemoryHigh -p MemoryMax
sudo journalctl -k --since today | grep -Ei 'out of memory|oom-kill|killed process' || true
df -h /mnt/db_data
```

Consulta también `INFO memory`, `INFO persistence`, `INFO stats` y latencia con una cuenta autorizada. Vigila `used_memory_rss`, `mem_not_counted_for_evict`, errores OOM, `aof_last_write_status`, `aof_last_bgrewrite_status`, `rdb_last_bgsave_status`, duración del fork y espacio libre. Evita reescrituras o respaldos pesados de PostgreSQL y Redis a la vez. La configuración de overcommit y THP requiere coordinación del host: este script no cambia parámetros globales que afecten a PostgreSQL.

## 7. Persistencia y permisos de escritura

Se activa RDB más AOF con `appendfsync everysec`; una caída puede perder aproximadamente el último segundo de escrituras, sin prometer pérdida cero. Redis 7 usa AOF multipartes: base, incrementos y manifiesto dentro de `appendonlydir`. Copiar solo un archivo `appendonly.aof` no es un respaldo completo. [Persistencia de Redis](https://redis.io/docs/latest/operate/oss_and_stack/management/persistence/).

Datos: usuario `redis`, grupo `redis`, directorio `0750`; el servicio tiene `UMask=0077`. Configuración: `root:redis`, `0640`. El padre `/mnt/db_data` debe permitir atravesar la ruta a `redis`, sin otorgar acceso a los datos de PostgreSQL.

El servicio utiliza `ProtectSystem=strict` y permite escritura exclusivamente en `/mnt/db_data/redis` y `/run/cociber-redis`. Si cambias el directorio, cambia **también** `ReadWritePaths` en un drop-in de este servicio; no amplíes la escritura a todo `/mnt/db_data` ni a `/etc`. [Restricciones de rutas de systemd](https://www.freedesktop.org/software/systemd/man/latest/systemd.exec.html).

Si AppArmor rechaza el acceso, comprueba el perfil que corresponde al binario real:

```bash
sudo aa-status
sudo systemctl show cociber-redis -p ExecStart -p AppArmorProfile -p ReadWritePaths
sudo journalctl -k --since '15 minutes ago' | grep -i apparmor || true
```

Un perfil del paquete para `/usr/bin/redis-server` no se presupone aplicado al binario privado `/opt/cociber-redis/.../bin/redis-server`. Si existe un perfil que sí lo vincula, adapta su inclusión local con `configs/redis/apparmor.local.example`, revisa las rutas y recarga **ese perfil exacto** mediante `apparmor_parser -r RUTA_DEL_PERFIL`. El ejemplo no se instala automáticamente y no es un perfil autónomo. Conserva AppArmor habilitado. [Administración de perfiles en Ubuntu](https://ubuntu.com/server/docs/security-apparmor/).

## 8. Respaldo y recuperación

Programa una ventana: detener Redis afecta autenticación, límites y terminales de Cociber CTF. Este respaldo offline evita una copia inconsistente durante una reescritura; conserva la carpeta completa de datos y la configuración. El destino debe ser un montaje de almacenamiento externo protegido, distinto tanto del disco del SO de 50 GB como del disco de datos de 2 TB. **No escribas el respaldo de datos en `/var/backups` del SO.** Los respaldos pequeños de configuración que crea el instalador son diferentes.

Sustituye `/RUTA_DEL_RESPALDO_EXTERNO` por el punto de montaje externo real. El bloque rechaza una carpeta sin montar y los filesystems del SO o de los datos; exige espacio para el tamaño sin comprimir más 1 GiB de margen. La persona que despliega debe verificar además que el almacenamiento cubre la pérdida de esta VM/host, no solamente que tenga otro nombre.

```bash
sudo bash <<'BASH'
set -Eeuo pipefail
umask 077
REDIS_BACKUP_MOUNT=/RUTA_DEL_RESPALDO_EXTERNO
mountpoint -q "$REDIS_BACKUP_MOUNT" || { printf 'El destino externo no está montado.\n' >&2; exit 1; }
REDIS_BACKUP_MOUNT=$(realpath -- "$REDIS_BACKUP_MOUNT")
REDIS_BACKUP_DEVICE=$(stat -c %d "$REDIS_BACKUP_MOUNT")
[[ "$REDIS_BACKUP_DEVICE" != "$(stat -c %d /)" && "$REDIS_BACKUP_DEVICE" != "$(stat -c %d /mnt/db_data)" ]] || { printf 'No se permite respaldar en el disco SO ni en el de datos.\n' >&2; exit 1; }
findmnt --mountpoint "$REDIS_BACKUP_MOUNT"
df -h "$REDIS_BACKUP_MOUNT"
REDIS_WAS_ACTIVE=no
if systemctl is-active --quiet cociber-redis; then REDIS_WAS_ACTIVE=yes; fi
trap 'if [[ "$REDIS_WAS_ACTIVE" == yes ]]; then systemctl start cociber-redis || exit 1; fi' EXIT
systemctl stop cociber-redis
REDIS_BACKUP_BYTES=$(du -sb /mnt/db_data/redis /etc/cociber-redis | awk '{total += $1} END {printf "%.0f", total}')
REDIS_BACKUP_FREE=$(df -B1 --output=avail "$REDIS_BACKUP_MOUNT" | awk 'NR == 2 {print $1}')
(( REDIS_BACKUP_FREE >= REDIS_BACKUP_BYTES + 1073741824 )) || { printf 'El destino externo no tiene espacio suficiente para el respaldo.\n' >&2; exit 1; }
REDIS_BACKUP=$(mktemp -d "$REDIS_BACKUP_MOUNT/redis-backup-$(date -u +%Y%m%dT%H%M%S).XXXXXXXX")
tar --numeric-owner -czf "$REDIS_BACKUP/data.tar.gz" -C /mnt/db_data/redis .
tar --numeric-owner -czf "$REDIS_BACKUP/config.tar.gz" -C /etc/cociber-redis .
(
  cd -- "$REDIS_BACKUP"
  sha256sum data.tar.gz config.tar.gz > SHA256SUMS
  sha256sum -c SHA256SUMS
)
if [[ "$REDIS_WAS_ACTIVE" == yes ]]; then systemctl start cociber-redis; fi
trap - EXIT
printf 'Respaldo externo verificado: %s\n' "$REDIS_BACKUP"
BASH
```

Si algún comando de respaldo falla, no supongas que el respaldo es válido. El bloque intenta volver a iniciar Redis si estaba activo; comprueba igualmente su estado y conserva la salida del error sin publicar configuración privada. No apliques `redis-check-aof --fix` al único original: puede eliminar datos. Haz primero una copia y ensaya la restauración con **la misma versión** en un entorno separado.

Para revertir configuración, elige el directorio concreto `config-FECHA-PID` que imprimió el instalador. Detén el servicio, restaura de ese directorio `redis.conf`, `users.acl` y la unidad previa si existen; restaura permisos `root:redis 0640`, ejecuta `systemctl daemon-reload`, inicia y repite PONG, versión y permisos. El prefijo anterior queda anotado en `previous-prefix.txt`; no cambies a una versión anterior si no se ha verificado compatibilidad con los archivos de datos.

Para restaurar datos, conserva los actuales con otro nombre en el mismo montaje, crea de nuevo `/mnt/db_data/redis` con propietario `redis:redis`, verifica el hash del respaldo y extrae su **contenido completo** dentro de esa carpeta con Redis detenido. Revisa propietario y permisos, inicia con Redis 7.4.11 y comprueba PONG, `INFO persistence` y el funcionamiento de sesiones. No sobrescribas ni borres el directorio PostgreSQL. El respaldo de ACL contiene hashes sensibles y debe mantener el mismo tratamiento privado que el original.

## Criterios para dar Redis por instalado

- `--apply` termina correctamente y el proceso activo informa `7.4.11`.
- PONG autenticado funciona y el acceso anónimo devuelve NOAUTH.
- Solo están abiertas las direcciones previstas y el firewall permite únicamente la aplicación autorizada.
- Configuración y ACL tienen permisos correctos, sin secretos en Git.
- PostgreSQL y Redis mantienen margen de RAM y disco durante persistencia.
- Se probó un respaldo y una restauración, además de las sesiones reales de Cociber CTF.

Esta entrega contiene archivos y comandos revisados; la ejecución y aceptación en lab-db-ctf se registran después de aplicar el procedimiento en esa VM.
