# 6. Aceptación, respaldo y recuperación

## Verificar el servidor después de instalar

En **lab-db-ctf, 10.10.10.14**:

```bash
findmnt /mnt/db_data
df -hT / /mnt/db_data
sudo pg_lsclusters
sudo systemctl status postgresql@16-main --no-pager
sudo systemctl status cociber-redis --no-pager
sudo ss -ltnp | grep -E ':(5432|6379)\b'
sudo -u postgres psql -X -d cociber_ctf -c 'SHOW server_version;'
sudo -u postgres psql -X -d cociber_ctf -c 'SHOW data_directory;'
sudo -u postgres psql -X -d cociber_ctf -c 'SHOW shared_buffers; SHOW effective_cache_size; SHOW work_mem; SHOW maintenance_work_mem;'
sudo -u postgres psql -X -d cociber_ctf -c "SELECT rolname,rolsuper FROM pg_roles WHERE rolname IN ('cociberctf','cociber_app');"
sudo -u postgres psql -X -d cociber_ctf -c "SELECT tablename FROM pg_tables WHERE schemaname='public' ORDER BY tablename;"
```

El esquema suministrado tiene **19 tablas**. La cuenta administrativa SQL debe
tener `rolsuper=true`; la cuenta de la API debe tener `false`.

Desde **10.10.10.13**, prueba las dos conexiones autenticadas con los comandos
de las guías. Comprueba que Redis contesta `PONG`, identifica al usuario
correcto y rechaza una conexión sin autenticación. Desde otro equipo de la red,
comprueba que los puertos de datos no sean accesibles. No publiques la salida
de `ACL LIST`, URLs privadas o archivos de entorno.

En la aplicación, valida: acceso de administrador y estudiante, catálogo,
asignación por grupos, envío de flag, ranking y apertura/cierre de terminal.
Si migraste datos, compara también estos recuentos con el origen:

```sql
SELECT count(*) AS usuarios FROM users;
SELECT count(*) AS retos_publicados FROM challenges WHERE is_published;
SELECT count(*) AS completados, coalesce(sum(awarded_points),0) AS puntos
FROM challenge_completions;
```

## Memoria y almacenamiento bajo carga

```bash
free -h
vmstat 1 10
sudo systemd-cgtop -b -n 1
sudo journalctl -k --since '1 hour ago' | grep -Ei 'out of memory|oom|killed process' || true
df -h /mnt/db_data
sudo -u postgres psql -X -d cociber_ctf -c "SELECT state,count(*) FROM pg_stat_activity GROUP BY state;"
```

Redis debe medirse con `INFO memory` antes, durante y después de `BGSAVE` o
reescrituras AOF controladas. El límite de 8 GB no garantiza un RSS de 8 GB.
No programes mantenimientos de PostgreSQL y Redis simultáneamente sin margen
medido. Un `MemoryMax` demasiado bajo convierte presión de memoria en un
reinicio del servicio; no evita por sí solo una interrupción.

El espacio de 1850/150 GB requiere vigilancia sobre el disco compartido. Las
carpetas no son cuotas. Los respaldos deben escribirse en un almacenamiento
**externo** distinto del disco de datos y del SO de 50 GB.

El disco del SO es de 50G, pero la raíz LVM actualmente tiene **24G**, con
aproximadamente 15G libres en el inventario recibido. Comprueba `/` además
del volumen de datos y no guardes allí los respaldos completos.

## Scripts de respaldo listos para ejecutar

Los scripts de este mismo proyecto permiten realizar respaldos de PostgreSQL y Redis ya instalados, sin restaurar ni modificar las tablas. **En la VM 10.10.10.14** utiliza `sudo bash scripts/respaldo_ctf_nativo.sh /RUTA_EXTERNA_DE_RESPALDOS`. Para el entorno antiguo Docker en Windows utiliza `scripts/respaldo_ctf_docker.ps1`. Lee el procedimiento completo, los requisitos de permisos y la verificación de archivos en [Respaldos PostgreSQL y Redis](09_RESPALDOS_POSTGRES_REDIS.md).

## Respaldo PostgreSQL

Define `BACKUP_DIR` con una ruta externa real montada, con espacio suficiente,
y permisos de escritura para `postgres`. No uses literalmente este ejemplo:

```bash
BACKUP_DIR=/RUTA_DEL_RESPALDO_EXTERNO
findmnt -T "$BACKUP_DIR"
df -h "$BACKUP_DIR"
sudo -u postgres pg_dump -Fc --no-owner --no-privileges -d cociber_ctf \
  -f "$BACKUP_DIR/cociber-ctf-$(date -u +%Y%m%dT%H%M%SZ).dump"
```

`pg_dump` conserva el contenido de una base; los roles globales y sus hashes
requieren un respaldo adicional protegido. Para inventariar los roles sin
incluir hashes de contraseñas:

```bash
sudo -u postgres pg_dumpall --roles-only --no-role-passwords
```

Para recuperar credenciales se conserva por separado el archivo privado de
despliegue. Comprueba los dumps con `pg_restore --list` y realiza periódicamente
una restauración **en otra base/servidor de prueba**. No pruebes restauraciones
destructivas sobre la base de trabajo.

## Redis y reinicio

Sigue el respaldo coherente de AOF/RDB de la guía Redis. No copies un único
archivo AOF si el motor utiliza un manifiesto y varios segmentos. Una copia
incompleta no sirve como recuperación.

Antes de declarar terminado el despliegue real, reinicia el servidor en una
ventana aprobada y repite las pruebas de montaje, servicios, autenticación y
aplicación. El montaje de datos debe estar disponible antes de iniciar los motores.
Las pruebas locales de SQL y ACL de esta entrega no sustituyen esta prueba de
arranque en la VM real.

Referencia: [respaldo lógico PostgreSQL 16](https://www.postgresql.org/docs/16/backup-dump.html).
