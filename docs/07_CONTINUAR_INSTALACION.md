# Continuar desde el servidor ya preparado

**Punto de partida:** Ubuntu 26.04 en `lab-db-ctf`, `10.10.10.14/24`, ext4 ya
montado en `/mnt/db_data`, con carpetas `postgres` y `redis`. La API se
conectará desde `10.10.10.13`. No repitas el formateo ni el montaje.

## 1. Obtener el repositorio y preparar credenciales

En la **VM de bases**, con tu usuario administrativo:

```bash
sudo apt update
sudo apt install -y git ca-certificates curl python3
sudo git clone https://github.com/lavillamarin3-hash/cociber-ctf-deploy.git /opt/cociber-ctf-deploy
cd /opt/cociber-ctf-deploy
findmnt --mountpoint /mnt/db_data
df -h / /mnt/db_data
sudo chmod 0755 /mnt/db_data
```

El repositorio es privado: usa una sesión Git autorizada o transfiere una copia
por SSH, sin tokens en URLs. Si la carpeta ya existe, revisa su origen y estado
antes de actualizar. `pg_lsclusters` se instalará con PostgreSQL; su ausencia
actual es normal. Revisa [el inventario](01_SERVIDOR_Y_ALMACENAMIENTO.md).

Prepara `/etc/cociber-ctf/deploy-secrets.env` con la guía privada entregada y
las reglas de [00](00_CREDENCIALES_Y_PREPARACION.md). Usa los dos administradores
`cociberctf` y contraseñas distintas para la API `cociber_app`. El archivo debe
ser root:root, modo 0600. Sustituye los marcadores de la plantilla: los scripts
los rechazan. No hace falta crear un usuario Linux `cociberctf`.

## 2. Instalar PostgreSQL 16 y crear el cluster vacío

Sigue [02](02_POSTGRESQL_16.md) desde **“Instalar la versión 16 desde PGDG”**.
Instala primero `postgresql-common`, desactiva su creación automática de
clusters y después instala **postgresql-16** desde PGDG para `resolute`.
No uses el metapaquete genérico `postgresql`.

Después de instalar esos paquetes y confirmar que `16/main` no existe y la
carpeta de datos está vacía, los pasos esenciales de esa guía son:

```bash
sudo install -d -o postgres -g postgres -m 0700 /mnt/db_data/postgres
sudo pg_createcluster 16 main --datadir=/mnt/db_data/postgres --port=5432 --start-conf=manual -- --data-checksums --encoding=UTF8 --locale=C.UTF-8 --auth-local=peer --auth-host=scram-sha-256
sudo bash scripts/configure-postgresql.sh --check --app-ip 10.10.10.13
sudo bash scripts/configure-postgresql.sh --apply --app-ip 10.10.10.13
sudo systemctl daemon-reload
sudo systemctl start postgresql@16-main.service
```

Si se solicita `include_dir`, certificados o permisos, completa la sección 4
de la guía 02 antes de aplicar. Valida versión, directorio y configuración como
indica la sección 6; después activa el arranque normal con `start.conf=auto`
y `postgresql.service`.

Para una **base nueva**, comprueba y crea roles y las 19 tablas:

```bash
sudo bash scripts/bootstrap-database.sh --secrets-file /etc/cociber-ctf/deploy-secrets.env --runtime
sudo bash scripts/bootstrap-database.sh --secrets-file /etc/cociber-ctf/deploy-secrets.env --runtime --apply
```

Si vas a conservar usuarios, retos y ranking del entorno actual, **omite estos
dos comandos** y restaura siguiendo [05](05_APLICACION_Y_MIGRACION.md). El respaldo
ya contiene el esquema; no se ejecuta `01_schema.sql` encima de él.

## 3. Instalar Redis 7 nativo

Sigue [03](03_REDIS_7.md). Se usa **Redis 7.4.11**, versión y SHA-256 fijados,
compilado como servicio nativo. No se instala el paquete genérico Redis 8
disponible para este Ubuntu.

```bash
sudo bash scripts/configure-redis.sh --check
sudo bash scripts/configure-redis.sh --apply
sudo systemctl is-active cociber-redis.service
```

El instalador asigna la subcarpeta existente a `redis`, conserva el montaje y
crea las ACL desde el archivo privado. Si detecta un Redis o datos ajenos,
requieren migración: no continúes con una inicialización nueva.

## 4. Conectar la API de 10.10.10.13

En la VM de bases, revisa primero reglas existentes y acceso SSH. Si UFW está
activo, autoriza los puertos de datos para el origen de la aplicación:

```bash
sudo ufw allow from 10.10.10.13 to 10.10.10.14 port 5432 proto tcp comment 'Cociber APP PostgreSQL'
sudo ufw allow from 10.10.10.13 to 10.10.10.14 port 6379 proto tcp comment 'Cociber APP Redis'
sudo ufw status numbered
sudo python3 tools/write_application_env.py --secrets-file /etc/cociber-ctf/deploy-secrets.env --output /etc/cociber-ctf/application-db.env
```

No habilites UFW sin comprobar tu acceso administrativo. El archivo generado
contiene URLs con contraseñas codificadas: transfiérelo de forma privada a
**10.10.10.13** y combina sus cuatro variables con la configuración de la API.
Conserva claves JWT/HMAC y Guacamole/SSH. No transfieras a la API las credenciales
administrativas completas.

La API usa `cociber_app`, `MANAGE_SCHEMA_ON_STARTUP=false` y
`CTF_SEED_DEMO_DATA=false`. [05](05_APLICACION_Y_MIGRACION.md) explica TLS,
restauración y pruebas remotas. Crear un rol SQL no crea un administrador web.

## 5. Aceptación

Comprueba versiones 16/7, rutas, propietarios, RAM, puertos, conexión de la API
y rechazo de otros equipos. Verifica login, retos, puntaje y un reinicio
planificado con [06](06_ACEPTACION_Y_RESPALDO.md). Estos comandos todavía deben
ejecutarse y validarse en la VM real.
