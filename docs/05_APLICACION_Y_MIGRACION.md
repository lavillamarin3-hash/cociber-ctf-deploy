# 5. Aplicación y migración de datos

## Direcciones y cuentas

| Componente | Dirección | Puerto |
|---|---|---|
| Aplicación Cociber CTF | 10.10.10.13/24 | El que se configure en su proxy web |
| PostgreSQL 16 | 10.10.10.14/24 | 5432 |
| Redis 7 | 10.10.10.14/24 | 6379 |

El firewall y `pg_hba.conf` autorizan a **10.10.10.13/32**, no a toda la subred.
Mantén el acceso SSH administrativo permitido antes de aplicar cualquier regla
de firewall. Revisa `sudo ufw status numbered` y elimina reglas antiguas más
amplias solo después de identificarlas; añadir una regla `/32` no neutraliza
otra regla previa que permita a todos.

En el servidor de bases, las reglas nuevas de datos son:

```bash
sudo ufw allow from 10.10.10.13 to 10.10.10.14 port 5432 proto tcp comment 'Cociber APP PostgreSQL'
sudo ufw allow from 10.10.10.13 to 10.10.10.14 port 6379 proto tcp comment 'Cociber APP Redis'
sudo ufw status verbose
```

No actives UFW desde SSH sin revisar primero la regla de acceso administrativo
y su política por defecto. Los servicios escuchan en la IP privada indicada;
no se publican mediante una redirección de puertos hacia Internet.

## Archivo privado de conexión de la API

El aprovisionamiento con `bootstrap-database.sh --runtime` crea el rol SQL
`cociber_app`; el instalador Redis crea la cuenta ACL del mismo nombre cuando
encuentra `REDIS_APP_PASSWORD`. Ambas cuentas tienen contraseñas independientes.
`cociberctf` sigue disponible para tareas administrativas.

En **10.10.10.14**, genera solo las líneas de conexión:

```bash
cd /opt/cociber-ctf-deploy
sudo python3 tools/write_application_env.py \
  --secrets-file /etc/cociber-ctf/deploy-secrets.env \
  --output /etc/cociber-ctf/application-db.env
```

El programa crea el archivo con permisos `0600` y se niega a reemplazarlo si ya
existe. Codifica correctamente los caracteres especiales de las contraseñas
en las URLs. No copies una contraseña que contiene `/` directamente a una URL.

Transfiere el archivo de forma privada a la VM de aplicación y combina sus
líneas con la configuración **existente** de Cociber. Conserva
`JWT_SECRET`, `FIELD_HMAC_SECRET`, configuración de Guacamole y claves SSH;
este archivo parcial no las reemplaza ni las genera. No lo publiques en Git.

```ini
# Estructura de las líneas generadas, sin contraseñas reales:
DATABASE_URL='postgresql+asyncpg://cociber_app:CLAVE_CODIFICADA@10.10.10.14:5432/cociber_ctf?ssl=require'
REDIS_URL='redis://cociber_app:OTRA_CLAVE_CODIFICADA@10.10.10.14:6379/0'
MANAGE_SCHEMA_ON_STARTUP=false
CTF_SEED_DEMO_DATA=false
```

`MANAGE_SCHEMA_ON_STARTUP=false` es obligatorio con la cuenta SQL de ejecución:
el esquema se administra por separado y esta cuenta no puede hacer `ALTER
TABLE`. El arranque con ese valor tampoco crea usuarios ni datos de ejemplo.
Las etiquetas de roles se pueden cargar mediante `03_bootstrap_roles.sql`.

PostgreSQL exige TLS en la conexión remota. `ssl=require` permite verificar el
laboratorio inicialmente con el certificado temporal del paquete; cifra la
conexión, pero **no verifica la identidad del servidor**. Antes de un uso fuera
de ese entorno, instala un certificado con SAN `IP:10.10.10.14`, entrega su CA
a la cuenta del servicio de la API mediante `PGSSLROOTCERT` y genera la URL
con `--pg-ssl verify-full`. Para SQLAlchemy/asyncpg el parámetro es `ssl`, no
`sslmode` como argumento directo. Comprueba la cadena y el nombre del servidor.

La plantilla Redis utiliza TCP autenticado dentro de la red privada restringida;
no contiene TLS activado. Si el enlace cruza una red no confiable, configura
Redis TLS y `rediss://` con validación de CA antes de transportar credenciales
por ese enlace. El binario se compila con soporte TLS.

Referencias: [SSL de asyncpg](https://magicstack.github.io/asyncpg/current/api/index.html),
[control de acceso de Redis](https://redis.io/docs/latest/operate/oss_and_stack/management/security/acl/).

## Instalación nueva o conservación del laboratorio actual

Elige **un solo flujo** para PostgreSQL:

- **Nueva base vacía:** usa `00_roles.sql`, `01_schema.sql`,
  `03_bootstrap_roles.sql` y opcionalmente `02_runtime.sql`, mediante el wrapper.
- **Conservar usuarios, retos y ranking:** restaura el respaldo de la base
  existente. No ejecutes `01_schema.sql` antes de una restauración completa,
  porque el dump ya contiene las tablas. No recrees usuarios ficticios para
  simular los datos que faltan.

### Exportar la base actual de Docker sin imprimir secretos

En la instalación actual, cierra los laboratorios activos antes del corte y
detén las escrituras de la API durante el respaldo final. No borres los
volúmenes Docker. Desde la carpeta real de la plataforma:

```bash
docker compose exec -T postgres sh -c 'pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" --format=custom --no-owner --no-privileges --file=/tmp/cociber-ctf.dump'
docker cp ctf_project-postgres-1:/tmp/cociber-ctf.dump ./cociber-ctf.dump
pg_restore --list ./cociber-ctf.dump
sha256sum ./cociber-ctf.dump
```

Estos son comandos para Bash/Ubuntu; en Windows usa PowerShell y comprueba el
nombre del contenedor con `docker compose ps`. Transfiere el dump por SSH a
una ruta privada del servidor nuevo, verifica su SHA-256 y conserva el origen.

### Restaurar en PostgreSQL nativo

Primero crea únicamente el administrador y la base vacía con este modo del
wrapper, que lee el archivo privado y **no ejecuta `01_schema.sql`**:

```bash
sudo bash scripts/bootstrap-database.sh --roles-only
sudo bash scripts/bootstrap-database.sh --roles-only --apply
```

No utilices el modo de instalación nueva en esta ruta. Comprueba que el destino está vacío:

```bash
sudo -u postgres psql -X -d cociber_ctf -c "SELECT count(*) FROM information_schema.tables WHERE table_schema='public';"
```

Con resultado **0**, un dump ya verificado, y un archivo legible por `postgres`:

```bash
sudo -u postgres pg_restore \
  --dbname=cociber_ctf --role=cociberctf \
  --no-owner --no-privileges --single-transaction --exit-on-error \
  /RUTA_PRIVADA_LEGIBLE_POR_POSTGRES/cociber-ctf.dump
```

La ruta anterior es un parámetro: reemplázala por el destino privado real del
respaldo. No uses `--clean` ni borres una base que contenga datos. Después de la
restauración, concede acceso a la cuenta de ejecución si aún no existe:

```bash
sudo bash scripts/bootstrap-database.sh --runtime-only
sudo bash scripts/bootstrap-database.sh --runtime-only --apply
```

Este modo ejecuta solo `02_runtime.sql`; no vuelve a crear tablas. Si el rol
ya existe, revisa sus permisos en lugar de cambiar su contraseña.

Compara usuarios, retos publicados, completados y suma de puntos con el origen.
No basta con que la portada web abra. Mantén la aplicación antigua disponible
para volver atrás hasta aprobar las comprobaciones de aceptación.

## Redis y la separación de Operación Cóndor

Redis contiene límites de intentos, reservas y sesiones temporales. No almacena
el ranking definitivo. Para el cambio de servidor, es preferible cerrar los
laboratorios y pedir un nuevo inicio de sesión que trasladar tickets de
terminal activos a otra topología. Si se requiere conservar Redis, utiliza el
flujo AOF/RDB de su guía durante una ventana de mantenimiento.

La web Operación Cóndor mantiene su **SQLite privada**; no es una tabla del
PostgreSQL de la plataforma. Su código y despliegue están en su repositorio
independiente. Al trasladarla, conserva esa SQLite y su archivo privado de
configuración, y actualiza en el reto la IP/URL de la víctima real. La IP
**10.10.10.14 pertenece a las bases**, no a la web vulnerable.
