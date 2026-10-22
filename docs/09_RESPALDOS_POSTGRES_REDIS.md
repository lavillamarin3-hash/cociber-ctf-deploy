# Respaldos de PostgreSQL y Redis — Cociber CTF

**Este procedimiento pertenece al repositorio de despliegue `cociber-ctf-deploy`, no al código de la plataforma ni a Guacamole.** Sus dos scripts hacen copias de seguridad: no ejecutan restauraciones, no borran tablas y no instalan bases.

## 1. Respaldo de la VM LAB-DB-POSTGRES (10.10.10.14)

Para el despliegue de producción, las bases **ya existen** en la VM y funcionan como servicios nativos: PostgreSQL 16, base `cociber_ctf`, y Redis 7 (instalado desde fuente en `/opt/cociber-redis/current/bin`). **Este es el script que debes utilizar en el servidor real.**

1. Conéctate mediante SSH a la VM y entra en el repositorio:

```bash
ssh TU_USUARIO@10.10.10.14
cd /opt/cociber-ctf-deploy
git pull --ff-only origin main
```

2. Prepara un directorio de respaldo en un **disco externo/montaje protegido con espacio suficiente**, no en el volumen principal de datos. Este ejemplo solo funciona si **/mnt/respaldos** ya es un almacenamiento montado y seguro:

```bash
findmnt -T /mnt/respaldos
df -h /mnt/respaldos
sudo mkdir -p /mnt/respaldos/ctf
sudo chmod 700 /mnt/respaldos/ctf
```

3. Ejecuta el respaldo (sin detener PostgreSQL o Redis):

```bash
sudo bash scripts/respaldo_ctf_nativo.sh /mnt/respaldos/ctf
```

Cuando pregunte, introduce la **contraseña del usuario administrativo Redis `cociberctf`**. La cuenta de aplicación `cociber_app` no dispone de permisos de sincronización para crear el RDB. No escribas claves en comandos, capturas ni documentos públicos.

**Resultado:** una carpeta `nativo_FECHA_XXXXXX` con `postgres_ctf.dump`, `redis_ctf.rdb`, `roles_sin_contrasenas.sql`, `SHA256SUMS.txt` y `LEEME.txt`. Si la ejecución falla, **NO** consideres válidos los archivos parciales.

El respaldo de Redis incluye **todas las bases lógicas de la misma instancia Redis**. No realiza operaciones sobre la base independiente de Apache Guacamole.

## 2. Respaldo de la versión original en Docker (Windows 11)

Este script es para tu computadora de desarrollo si todavía ejecutas **PostgreSQL y Redis dentro del Compose antiguo**. No lo ejecutes en el servidor web de producción, donde los contenedores de base de datos no existirán.

En Windows, con Docker Desktop iniciado, ejecuta PowerShell desde el directorio que contiene el script:

```powershell
.\respaldo_ctf_docker.ps1 -RutaProyecto 'C:\Users\HP\Documents\Codex\Proyecto_CTF_Fase5_Laboratorio_Ranking_Top10\ctf_project'
```

Si lo ejecutas desde la carpeta raíz del repositorio `cociber-ctf-deploy`, utiliza:

```powershell
.\scripts\respaldo_ctf_docker.ps1 -RutaProyecto 'C:\Users\HP\Documents\Codex\Proyecto_CTF_Fase5_Laboratorio_Ranking_Top10\ctf_project'
```

Se guarda en `$HOME\Respaldos_CTF\docker_FECHA`: `postgres_ctf.dump`, `redis_ctf.rdb`, `SHA256SUMS.txt` y `LEEME.txt`. Los contenedores deben estar activos.

## 3. Verificación y precauciones

Comprueba el resultado del servidor Linux con las rutas que el script imprimió:

```bash
cd /mnt/respaldos/ctf/nativo_FECHA_XXXXXX   # reemplazar por ruta real
sha256sum -c SHA256SUMS.txt
pg_restore --list postgres_ctf.dump | head
/opt/cociber-redis/current/bin/redis-check-rdb redis_ctf.rdb
```

- No subas archivos `.dump`, `.rdb`, `.env` ni contraseñas a GitHub.
- Conserva una **copia adicional fuera de la VM**, cifrada o en un medio con acceso restringido.
- `pg_dump` y Redis `--rdb` capturan momentos distintos. Para un respaldo de migración final, detén primero las escrituras del aplicativo y cierra las sesiones de estudiantes.
- El archivo `roles_sin_contrasenas.sql` es un inventario, **no** incluye contraseñas. Respalda credenciales y certificados por separado de forma privada.
- Una restauración debe probarse **en un servidor de pruebas aislado**, nunca sobre PostgreSQL y Redis productivos que ya contienen datos.
- Redis utiliza AOF de varios archivos para su persistencia operativa. `redis_ctf.rdb` es una instantánea portátil obtenida por el protocolo de Redis; no sustituye un plan de recuperación de infraestructura.

Consulta también [comprobaciones y recuperación](06_ACEPTACION_Y_RESPALDO.md).
