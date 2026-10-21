# 0. Credenciales para continuar la instalación

Ubuntu 26.04 ya está instalado en **lab-db-ctf**, con el disco ext4 montado en
`/mnt/db_data` y las carpetas de los motores creadas. Continúa desde las
credenciales y la instalación de las bases; no repitas la preparación del SO
ni el formateo.

Todo el procedimiento nativo de bases se ejecuta en **10.10.10.14**, no en el
servidor de aplicación **10.10.10.13**. Se necesita acceso `sudo`. Los motores
utilizan los usuarios de sistema `postgres` y `redis`; `cociberctf` es el
administrador lógico de cada motor y no necesita una cuenta Linux del mismo
nombre.

Clona este repositorio en una ruta de administración legible por `postgres`,
por ejemplo `/opt/cociber-ctf-deploy`. No lo clones dentro de `/root` si vas a
ejecutar archivos SQL como `postgres`.

El bloque siguiente es para la **primera descarga**. Si `/opt/cociber-ctf-deploy`
ya existe, actualiza esa copia según [el README](../README.md) y omite
`git clone`. Conserva el archivo privado existente.

```bash
sudo apt update
sudo apt install -y git ca-certificates curl python3
sudo git clone https://github.com/lavillamarin3-hash/cociber-ctf-deploy.git /opt/cociber-ctf-deploy
cd /opt/cociber-ctf-deploy
sudo install -d -o root -g root -m 0700 /etc/cociber-ctf
if ! sudo test -e /etc/cociber-ctf/deploy-secrets.env; then
  sudo install -o root -g root -m 0600 .env.example /etc/cociber-ctf/deploy-secrets.env
fi
sudoedit /etc/cociber-ctf/deploy-secrets.env
```

Si el repositorio es privado, clónalo mediante la sesión Git autorizada o
transfiere el paquete de entrega por SSH. No pongas un token de GitHub en la
URL ni en la guía.

Escribe las dos contraseñas administrativas acordadas en `PG_ADMIN_PASSWORD`
y `REDIS_ADMIN_PASSWORD`. La guía privada entregada por separado ya contiene
los comandos con esos valores. Usa comillas simples para conservar símbolos
como `*` y `/`. Mantén el archivo fuera del repositorio.

Para las cuentas de la API, genera dos contraseñas distintas de al menos 20
caracteres y guárdalas en `PG_APP_PASSWORD` y `REDIS_APP_PASSWORD`. Puedes obtener
cada valor con `openssl rand -hex 24` y pegarlo mediante `sudoedit`. No reutilices
las contraseñas administrativas para estas cuentas.

Los validadores rechazan los marcadores públicos `REEMPLAZAR_*` y `GENERAR_*`. Si no vas a utilizar una cuenta opcional, elimina su línea de contraseña del archivo privado; no dejes el marcador como si fuera una contraseña válida.

```bash
sudo chown root:root /etc/cociber-ctf/deploy-secrets.env
sudo chmod 0600 /etc/cociber-ctf/deploy-secrets.env
sudo stat -c '%U:%G %a %n' /etc/cociber-ctf/deploy-secrets.env
```

No ejecutes `cat` sobre ese archivo en una pantalla compartida. Los scripts
leen las contraseñas sin incluirlas como argumentos de proceso. Si necesitas
repetir el despliegue, conserva los valores existentes y utiliza el flujo de
migración; no vuelvas a instalar la plantilla encima del archivo privado.

Continúa con [almacenamiento](01_SERVIDOR_Y_ALMACENAMIENTO.md), PostgreSQL y Redis.
