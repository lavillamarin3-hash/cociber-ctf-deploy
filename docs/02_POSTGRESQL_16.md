# PostgreSQL 16 nativo en lab-db-ctf

Este procedimiento prepara PostgreSQL **16**, no la versión que instale el metapaquete genérico de Ubuntu. No utiliza Docker. La instalación de Redis se describe por separado; ambos servicios comparten la misma VM y su presupuesto de memoria.

| Elemento | Valor |
|---|---|
| Sistema | Ubuntu Server 26.04 LTS, `resolute` |
| VM de datos | `lab-db-ctf`, `10.10.10.14/24` |
| VM de aplicación autorizada | `10.10.10.13/32` |
| Recursos | 4 vCPU, 32 GB RAM |
| Disco del sistema | 50G virtuales; raíz LVM actualmente de 24G, para paquetes y logs |
| Disco de datos | 2 TB montados en `/mnt/db_data` |
| Datos PostgreSQL | `/mnt/db_data/postgres` |
| Cluster / servicio | `16/main` / `postgresql@16-main.service` |
| Base de aplicación | `cociber_ctf` |
| Administrador SQL solicitado | `cociberctf`, `SUPERUSER` |
| Ejecución recomendada de la API | `cociber_app`, sin superusuario; SQL opcional `02_runtime.sql` |

`cociberctf` es un rol de PostgreSQL, no una cuenta de acceso a la plataforma. La creación de usuarios administradores de Cociber CTF se realiza después, con el procedimiento de la aplicación.

## 1. Distinguir una instalación nueva de una migración

El SO, el montaje ext4 en `/mnt/db_data` y las subcarpetas ya están preparados
según el inventario recibido. Confirma el montaje sin repetirlo y continúa en
la sección 2. Que `pg_lsclusters` no exista antes de instalar los paquetes es normal.

Ejecuta primero comprobaciones de lectura:

```bash
hostnamectl
ip -4 address
lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINTS
findmnt --mountpoint /mnt/db_data
df -h / /mnt/db_data
free -h
```

`/mnt/db_data` debe ser un punto de montaje real del disco de datos, preparado según la guía de almacenamiento. Si el montaje no existe, detente: crear una carpeta con ese nombre en `/` consumiría el disco del sistema. Esta guía no formatea discos ni mueve datos.

Si `pg_lsclusters` ya existe, ejecútalo también:

```bash
pg_lsclusters
```

- **Instalación nueva:** no hay cluster `16/main`, la carpeta destino está ausente o vacía y todavía no existen datos que conservar. Sigue la sección 2.
- **Instalación con datos:** existe cualquier cluster o un directorio PostgreSQL con contenido. No ejecutes `pg_createcluster` sobre ese directorio, no borres clusters y no copies una carpeta activa con `cp`. Haz un respaldo verificable, programa mantenimiento y utiliza el procedimiento de migración de la sección 9.

## 2. Instalar la versión 16 desde PGDG

PGDG publica paquetes para Ubuntu 26.04 `resolute`. Instalar los paquetes con sufijo `-16` conserva la versión mayor y permite recibir sus actualizaciones menores. La disponibilidad de `resolute` y el formato del repositorio se verificaron en la [página oficial de PostgreSQL para Ubuntu](https://www.postgresql.org/download/linux/ubuntu/).

```bash
sudo apt update
sudo apt install -y postgresql-common curl ca-certificates ssl-cert
```

En una **VM nueva**, revisa el archivo siguiente y establece `create_main_cluster = false` antes de instalar el servidor. Así el paquete no crea datos automáticamente en el disco del sistema:

```bash
sudoedit /etc/postgresql-common/createcluster.conf
```

Configuración que debe quedar activa una sola vez:

```ini
create_main_cluster = false
```

Agrega el repositorio firmado. El comando obtiene la arquitectura real de la VM:

```bash
sudo install -d -m 0755 /usr/share/postgresql-common/pgdg
sudo curl --fail --show-error --location https://www.postgresql.org/media/keys/ACCC4CF8.asc --output /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc
sudo chmod 0644 /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc
```

```bash
printf 'Types: deb\nURIs: https://apt.postgresql.org/pub/repos/apt\nSuites: resolute-pgdg\nComponents: main\nArchitectures: %s\nSigned-By: /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc\n' "$(dpkg --print-architecture)" | sudo tee /etc/apt/sources.list.d/pgdg.sources >/dev/null
sudo apt update
apt-cache policy postgresql-16 postgresql-client-16
sudo apt install -y postgresql-16 postgresql-client-16
/usr/lib/postgresql/16/bin/postgres --version
/usr/lib/postgresql/16/bin/psql --version
pg_lsclusters
```

Si ya existía `/etc/apt/sources.list.d/pgdg.sources`, revisa y respalda su contenido antes de escribirlo. No añadas una segunda definición del mismo repositorio.

## 3. Crear el cluster nuevo en el disco de datos

Solo para la ruta nueva y vacía. Si `pg_lsclusters` muestra `16/main`, detente y comprueba su ubicación antes de continuar.

```bash
sudo mountpoint /mnt/db_data
sudo test ! -e /mnt/db_data/postgres/PG_VERSION
sudo install -d -o postgres -g postgres -m 0700 /mnt/db_data/postgres
sudo find /mnt/db_data/postgres -mindepth 1 -maxdepth 1 -print
```

El último comando debe producir **cero entradas**. Si hay cualquier archivo, no continúes. No se limpia la carpeta automáticamente.

```bash
sudo pg_createcluster 16 main --datadir=/mnt/db_data/postgres --port=5432 --start-conf=manual -- --data-checksums --encoding=UTF8 --locale=C.UTF-8 --auth-local=peer --auth-host=scram-sha-256
pg_lsclusters
```

El cluster queda detenido para preparar acceso y memoria antes de exponerlo. Las opciones de creación y la separación entre configuración Debian/Ubuntu y directorio de datos están descritas en el [manual de `pg_createcluster`](https://manpages.debian.org/testing/postgresql-common/pg_createcluster.1.en.html).

No se hace `chown -R` sobre `/mnt/db_data`: Redis tendrá su propio propietario y directorio. Los datos de PostgreSQL incluyen WAL dentro de su directorio salvo configuración deliberada distinta. Consulta la [estructura oficial del cluster](https://www.postgresql.org/docs/16/storage-file-layout.html).

## 4. Preparar configuración, TLS y autenticación

Desde la raíz de este repositorio:

```bash
sudo bash scripts/configure-postgresql.sh --check --app-ip 10.10.10.13
```

El script exige Ubuntu 26.04, la IP de datos, un montaje real, datos de versión 16 con propietario `postgres` y modo `0700`, y que `16/main` ya apunte al destino correcto. No crea clusters, no instala paquetes, no solicita secretos ni reinicia servicios.

Si solicita habilitar los fragmentos, revisa `/etc/postgresql/16/main/postgresql.conf` y deja activa una sola línea al final de la configuración:

```ini
include_dir = 'conf.d'
```

El certificado inicial procede del paquete `ssl-cert`. Si PostgreSQL no puede leer su clave, revisa el acceso del usuario antes de continuar:

```bash
id postgres
sudo -u postgres test -r /etc/ssl/certs/ssl-cert-snakeoil.pem
sudo -u postgres test -r /etc/ssl/private/ssl-cert-snakeoil.key
```

En una instalación estándar puede ser necesario agregar el usuario al grupo del certificado y volver a iniciar su servicio después:

```bash
sudo adduser postgres ssl-cert
```

El certificado `snakeoil` permite comprobar TLS en este laboratorio privado con `sslmode=require`, pero **no acredita la identidad `10.10.10.14` para `verify-full`**. El modo inicial cifra la conexión sin verificar esa identidad. Como mejora posterior para producción, instala un certificado con `subjectAltName=IP:10.10.10.14` firmado por una CA confiable, una clave privada accesible solo por el propietario autorizado, y cambia las rutas `ssl_cert_file`/`ssl_key_file` de la plantilla. PostgreSQL documenta las condiciones de certificado y clave en [SSL del servidor](https://www.postgresql.org/docs/16/ssl-tcp.html). Esa mejora no bloquea la puesta en marcha del laboratorio.

Aplica la configuración de acceso y disco. El límite cgroup es opcional y
requiere añadir `--memory-guard` tras evaluar el presupuesto de la sección 5:

```bash
sudo bash scripts/configure-postgresql.sh --apply --app-ip 10.10.10.13
```

Archivos instalados:

| Plantilla | Destino |
|---|---|
| `configs/postgresql/99-cociber.conf` | `/etc/postgresql/16/main/conf.d/99-cociber.conf` |
| `configs/postgresql/pg_hba.conf.template` | `/etc/postgresql/16/main/pg_hba.conf`, con la IP de aplicación `/32` |
| `configs/postgresql/10-data-mount.conf` | `/etc/systemd/system/postgresql@16-main.service.d/10-data-mount.conf`, dependencia obligatoria del disco |
| `configs/postgresql/20-memory-guard.conf` | `/etc/systemd/system/postgresql@16-main.service.d/20-memory-guard.conf`, si se pide |

El script respalda la configuración anterior en `/var/backups/cociber-ctf/pg-config-FECHA-PID/`. **Este respaldo de configuración no es un respaldo de la base de datos.** Revisa los valores y conserva la ruta impresa para poder revertir.

El acceso de red se limita a `10.10.10.14` y `localhost`; no se utiliza `listen_addresses='*'`. HBA permite al rol `cociber_app` conectarse solamente a `cociber_ctf` desde `10.10.10.13/32`, con TLS y SCRAM. No se abre todo `10.10.10.0/24`, ni se autoriza superusuario remoto desde la aplicación. El firewall debe usar el mismo origen `/32`, según la guía de red. Las reglas HBA se procesan por orden: [documentación de `pg_hba.conf`](https://www.postgresql.org/docs/16/auth-pg-hba-conf.html). Las contraseñas nuevas se almacenan con [SCRAM-SHA-256](https://www.postgresql.org/docs/16/auth-password.html).

## 5. Memoria: configuración de partida, no una reserva de 20 GB

Se mantienen los cuatro valores de memoria de la especificación:

| Parámetro | Valor | Interpretación |
|---|---|---|
| `shared_buffers` | `8GB` | Caché compartida del servidor |
| `effective_cache_size` | `20GB` | Estimación del planificador; **no reserva RAM y no limita consumo** |
| `work_mem` | `64MB` | Memoria por operación de ordenación/hash; una consulta puede usar varias |
| `maintenance_work_mem` | `2GB` | Memoria para operaciones de mantenimiento; controlar su concurrencia |

También se conservan `min_wal_size=2GB` y `max_wal_size=16GB`. Corresponden a WAL en disco, no a RAM; `max_wal_size` no es una cuota rígida del almacenamiento, según la [configuración oficial de WAL](https://www.postgresql.org/docs/16/runtime-config-wal.html#GUC-MAX-WAL-SIZE).

El significado de la estimación de caché está en [planificación de consultas](https://www.postgresql.org/docs/16/runtime-config-query.html#GUC-EFFECTIVE-CACHE-SIZE). La configuración tampoco implica que PostgreSQL use siempre 8 + 20 GB.

Para reducir presión en esta VM compartida se proponen 60 conexiones, tres reservadas al superusuario, `hash_mem_multiplier=1.0`, tres autovacuum de `256MB`, dos trabajadores paralelos globales y uno por consulta. El multiplicador de hash se reduce respecto del valor predeterminado `2.0`; los cuatro valores solicitados se conservan. Los trabajadores paralelos y los operadores simultáneos multiplican la memoria de trabajo: [memoria y paralelismo en PostgreSQL 16](https://www.postgresql.org/docs/16/runtime-config-resource.html).

Ejemplo de capacidad **orientativo**, no cota del proceso: 20 consultas con dos operaciones de `64MB` cada una ya suman aproximadamente 2,5 GiB de trabajo, además de los buffers. Más operaciones, conexiones, mantenimiento o paralelismo aumentan esa cifra. La API debería mantener un pool acotado: por ejemplo, cuatro procesos con cinco conexiones cada uno consumen 20 conexiones antes de contar tareas auxiliares. Las reservas de conexión se describen en [conexiones de PostgreSQL](https://www.postgresql.org/docs/16/runtime-config-connection.html).

El drop-in opcional aplica `MemoryHigh=20G`, `MemoryMax=24G` y `MemorySwapMax=1G` al **servicio del cluster**, dejando nominalmente 8 GiB fuera de su máximo para Redis y Ubuntu. Esto no reserva esos 8 GiB ni sustituye un presupuesto global: si Redis y el SO necesitan más, reduce concurrencia, consumo o límites antes de abrir carga. `MemoryHigh` introduce presión y reclamación; al exceder `MemoryMax` puede producirse OOM **dentro del servicio**. No garantiza continuidad ni ausencia de OOM. Referencia: [control de recursos de systemd](https://www.freedesktop.org/software/systemd/man/latest/systemd.resource-control.html#MemoryHigh=).

Después de aplicar mide RAM, latencia, conexiones activas y temporales. Con `maintenance_work_mem=2GB`, ejecuta inicialmente una sola restauración o tarea manual pesada a la vez. Ajusta según carga, no incrementes conexiones para resolver una saturación de memoria.

## 6. Arrancar y validar antes de crear datos de aplicación

El drop-in del cluster espera `network-online.target`, además del disco. Comprueba qué gestor configura la interfaz de `10.10.10.14` y que su servicio de espera participe en ese target:

```bash
systemctl is-active systemd-networkd.service
systemctl is-active NetworkManager.service
systemctl list-dependencies network-online.target
```

Solo uno de los gestores debe corresponder a esa interfaz. Para `systemd-networkd`, habilita su espera si falta:

```bash
sudo systemctl enable systemd-networkd-wait-online.service
```

Si la interfaz utiliza NetworkManager, usa en cambio:

```bash
sudo systemctl enable NetworkManager-wait-online.service
```

No habilites un gestor diferente ni los dos servicios de espera sin revisar el Netplan existente. La interfaz de datos no debe quedar excluida como opcional de la espera. Después de reiniciar, confirma que `10.10.10.14` esté presente y que PostgreSQL escuche en ella: sin esa dirección podría iniciarse solo en loopback. No basta con que el target se llame “online”; debe existir una espera configurada para la interfaz real.

Los comandos siguientes arrancan el cluster nuevo que estaba detenido. Si se reaplica la configuración a un cluster que ya funciona, `start` no carga los cambios: programa mantenimiento y usa `sudo systemctl restart postgresql@16-main.service` después de respaldar y revisar la configuración.

```bash
sudo systemctl daemon-reload
sudo systemctl start postgresql@16-main.service
sudo systemctl status postgresql@16-main.service --no-pager -l
sudo -u postgres /usr/lib/postgresql/16/bin/psql -X -d postgres -c 'SELECT version();'
sudo -u postgres /usr/lib/postgresql/16/bin/psql -X -d postgres -c 'SHOW data_directory;'
sudo -u postgres /usr/lib/postgresql/16/bin/psql -X -d postgres -c 'SHOW listen_addresses;'
sudo -u postgres /usr/lib/postgresql/16/bin/psql -X -d postgres -c 'SHOW password_encryption;'
```

Comprueba que no haya errores de archivos antes de continuar:

```bash
sudo -u postgres /usr/lib/postgresql/16/bin/psql -X -d postgres -c 'SELECT sourcefile, sourceline, name, error FROM pg_file_settings WHERE error IS NOT NULL;'
sudo -u postgres /usr/lib/postgresql/16/bin/psql -X -d postgres -c 'SELECT line_number, error FROM pg_hba_file_rules WHERE error IS NOT NULL;'
sudo ss -ltnp '( sport = :5432 )'
sudo systemctl show postgresql@16-main.service -p MemoryCurrent -p MemoryHigh -p MemoryMax -p MemorySwapMax
```

Las dos consultas de errores deben devolver cero filas. Se comprueban los archivos leídos mediante [pg_file_settings](https://www.postgresql.org/docs/16/view-pg-file-settings.html) y [pg_hba_file_rules](https://www.postgresql.org/docs/16/view-pg-hba-file-rules.html). PostgreSQL debe escuchar solamente en la IP asignada y loopback.

Para activar el arranque normal, tras validar:

```bash
printf 'auto\n' | sudo tee /etc/postgresql/16/main/start.conf >/dev/null
sudo systemctl daemon-reload
sudo systemctl enable postgresql.service
```

Un cambio de `shared_buffers`, conexiones o direcciones requiere reinicio del cluster en mantenimiento. No basta con `reload`. Revisa `pg_settings.pending_restart` después de cualquier cambio:

```bash
sudo -u postgres /usr/lib/postgresql/16/bin/psql -X -d postgres -c "SELECT name, setting, unit, pending_restart FROM pg_settings WHERE name IN ('shared_buffers','effective_cache_size','work_mem','maintenance_work_mem','max_connections','hash_mem_multiplier','autovacuum_work_mem');"
```

## 7. Roles SQL y esquema, sin contraseñas en Git ni argumentos

El archivo privado `/etc/cociber-ctf/deploy-secrets.env` debe pertenecer a `root:root`, modo `0600`, y contener `PG_ADMIN_PASSWORD` y, si se usa el rol de aplicación, `PG_APP_PASSWORD`. Lo prepara el operador por el procedimiento de secretos. No uses contraseñas en `psql -v`, URI, `env CLAVE=valor ...`, historial, capturas o argumentos de proceso. No actives `set -x`.

El procedimiento de bootstrap debe leer ese archivo como datos, pasar únicamente las variables necesarias por el entorno al usuario `postgres` y ejecutar `psql -X -v ON_ERROR_STOP=1`, en este orden:

1. `sql/00_roles.sql`, conectado a `postgres`: administrador SQL `cociberctf` y base `cociber_ctf`.
2. `sql/01_schema.sql`, conectado a `cociber_ctf`: esquema nuevo; exige que el destino esté vacío.
3. `sql/02_runtime.sql`, conectado a `cociber_ctf`, si se emplea `cociber_app`: permisos de ejecución sin superusuario.
4. `sql/03_bootstrap_roles.sql`, opcional: catálogo de etiquetas de roles de la plataforma; no crea cuentas personales.

Los SQL leen las contraseñas con `\getenv`; no contienen valores reales. Para una base completamente nueva, usa el wrapper de bootstrap documentado en la guía general:

```bash
sudo bash scripts/bootstrap-database.sh --secrets-file /etc/cociber-ctf/deploy-secrets.env --runtime --apply
```

Este paso **no se ejecuta en una base que ya tenga datos**, ni reemplaza migraciones. Después de restaurar una base existente, revisa y aplica únicamente los permisos de `02_runtime.sql` mediante el procedimiento administrativo de restauración, sin repetir los scripts de creación.

Para usar `cociber_app` con la API, el esquema debe existir y `MANAGE_SCHEMA_ON_STARTUP=false`. La creación/migración de tablas corresponde a un proceso administrativo separado. No conectes el proceso web como superusuario para compensar permisos DDL faltantes.

Desde LAB-APP, comprueba el acceso inicial del laboratorio cifrado con solicitud interactiva de contraseña:

```bash
psql 'host=10.10.10.14 port=5432 dbname=cociber_ctf user=cociber_app sslmode=require' -W -c 'SELECT current_user, current_database();'
```

Si posteriormente se instala el certificado con identidad correcta y una CA de confianza, cambia a verificación completa:

```bash
psql 'host=10.10.10.14 port=5432 dbname=cociber_ctf user=cociber_app sslmode=verify-full sslrootcert=/ruta/a/ca-laboratorio.crt' -W -c 'SELECT current_user, current_database();'
```

No guardes la contraseña dentro de esa cadena. Verifica que el mismo acceso falle desde un equipo no autorizado. La administración local sigue disponible con `sudo -u postgres psql` aunque el rol SQL administrador tenga contraseña.

## 8. Operación y comprobaciones

```bash
sudo -u postgres /usr/lib/postgresql/16/bin/psql -X -d cociber_ctf -c 'SELECT state, count(*) FROM pg_stat_activity GROUP BY state;'
sudo -u postgres /usr/lib/postgresql/16/bin/psql -X -d cociber_ctf -c 'SELECT datname, temp_files, temp_bytes FROM pg_stat_database WHERE datname = current_database();'
df -h / /mnt/db_data
free -h
sudo systemctl show postgresql@16-main.service -p MemoryCurrent -p MemoryPeak -p MemoryHigh -p MemoryMax
sudo journalctl -u postgresql@16-main.service --since '1 hour ago' --no-pager -n 60
```

Evita publicar logs o sesiones que incluyan sentencias administrativas o información privada. Para cambios posteriores, respalda la configuración y los datos, revisa los archivos, reinicia en mantenimiento si corresponde y repite las verificaciones. Los parámetros del archivo `postgresql.auto.conf` o de una sesión pueden prevalecer sobre la plantilla: revisa `pg_settings.source` y `sourcefile` si un valor no coincide.

## 9. Si ya existe una base o un cluster

No hay un comando automático de traslado en este repositorio. Antes de modificar un cluster existente:

1. Identifica versión, ruta, extensiones, propietarios, tamaño y clientes conectados.
2. Genera un respaldo lógico de la base y de roles/configuración en un destino privado. Comprueba su lectura y realiza una restauración de prueba en otro cluster vacío.
3. Programa mantenimiento y detén las escrituras de la aplicación. Decide entre restaurar en un cluster nuevo con la misma versión mayor o usar una migración de versión planificada.
4. Valida que el disco de datos esté montado y que el destino elegido sea nuevo y vacío. Nunca inicialices sobre el directorio con datos.
5. Restaura, comprueba tablas, relaciones, secuencias, extensiones y puntajes históricos. Solo después cambia la conexión de la aplicación.
6. Conserva el cluster y los respaldos originales hasta completar la aceptación. No ejecutes `01_schema.sql` sobre una restauración ni dupliques el esquema con el arranque automático de la API.

Un respaldo de archivos activos sin coordinación no equivale a un respaldo consistente. Elige el método indicado para tu escenario en [respaldo y restauración de PostgreSQL](https://www.postgresql.org/docs/16/backup.html), [pg_dump](https://www.postgresql.org/docs/16/app-pgdump.html) y [pg_restore](https://www.postgresql.org/docs/16/app-pgrestore.html). Comprueba la compatibilidad de versiones del cliente y servidor antes de exportar desde un PostgreSQL mayor que 16.

Si falla la nueva configuración antes de aceptar el servicio, consulta el log y restaura los archivos individuales desde el respaldo de configuración que imprimió el script. No reemplaces carpetas de datos como método de reversión de parámetros. Elimina únicamente un fragmento creado por este procedimiento si no había una versión anterior, revisa el drop-in instalado, ejecuta `systemctl daemon-reload` y arranca de nuevo el cluster en mantenimiento.
