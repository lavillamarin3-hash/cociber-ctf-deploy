# 1. Servidor y almacenamiento

Ejecuta estos pasos en **LAB-DB-POSTGRES — 10.10.10.14/24**, Ubuntu Server
26.04, 4 vCPU y 32 GB RAM. El servidor de aplicación es **10.10.10.13/24**.
Usa una consola administrativa y conserva otra sesión SSH abierta.

## Inventario antes de cambiar rutas

```bash
hostnamectl
cat /etc/os-release
ip -4 address
nproc
free -h
lsblk -o NAME,SIZE,FSTYPE,UUID,MOUNTPOINTS
findmnt -T /var/lib/postgresql
findmnt -T /mnt/db_data
df -hT
sudo pg_lsclusters
```

Confirma que el disco de datos es el de **2 TB**, no el del SO de 50 GB.
El sistema puede mostrar aproximadamente **1.82 TiB** para 2 TB decimales;
GB y GiB no son equivalentes. No uses un nombre como `/dev/sdb` sin comprobar
su UUID. Estas instrucciones no contienen `mkfs`, `wipefs` ni reparticionado.

Si el hostname aún no coincide:

```bash
sudo hostnamectl set-hostname LAB-DB-POSTGRES
```

No cambies la dirección IP a ciegas desde la misma conexión SSH. La dirección
10.10.10.14 debe estar configurada y responder antes de instalar los servicios.

## Si el disco ya está montado en /var/lib/postgresql

Primero identifica si existe un clúster con datos. Si existe, sigue la guía de
respaldo y abre una ventana de mantenimiento: detener PostgreSQL corta las
conexiones de la aplicación. No muevas un clúster mientras siga en ejecución.

La opción menos invasiva para el punto de montaje ya instalado es un **bind
mount**: se conserva el montaje original y se accede al mismo disco también
desde una ruta neutral. No se duplica su capacidad ni se copian los datos.

```bash
mountpoint /var/lib/postgresql
sudo install -d -m 0755 /mnt/db_data
find /mnt/db_data -mindepth 1 -maxdepth 1 -print
```

Continúa solo si `/var/lib/postgresql` es realmente el disco de datos y
`/mnt/db_data` está vacío y sin montar. Conserva una copia de fstab:

```bash
sudo cp -a /etc/fstab "/etc/fstab.cociber.$(date -u +%Y%m%dT%H%M%SZ).bak"
sudoedit /etc/fstab
```

Añade **una sola vez**, manteniendo la línea original del disco de datos:

```fstab
/var/lib/postgresql /mnt/db_data none bind,x-systemd.requires-mounts-for=/var/lib/postgresql 0 0
```

```bash
sudo findmnt --verify --verbose
sudo mount /mnt/db_data
findmnt /mnt/db_data
df -hT /mnt/db_data /var/lib/postgresql
sudo chmod 0755 /mnt/db_data
```

El bind anterior permanece deliberadamente después del despliegue. No borres
el directorio original: contiene el mismo disco. Las guías de los motores
utilizan `/mnt/db_data/postgres` y `/mnt/db_data/redis` como rutas canónicas.

### Alternativa: cambiar el montaje real a /mnt/db_data

Solo en una instalación vacía o durante una migración planificada, puede
modificarse la línea original de `/etc/fstab`, conservando **su UUID, tipo de
filesystem y opciones** y sustituyendo únicamente el destino por
`/mnt/db_data`. Requiere detener ambos motores, desmontar sin `-f` ni `-l`,
verificar que ningún proceso utiliza el disco y montar el destino nuevo.
No combines esta alternativa con el bind anterior. Evita hacerlo por SSH sin
una consola de recuperación y un respaldo externo probado.

## Crear las carpetas después de instalar los usuarios de los paquetes

PostgreSQL y Redis deben disponer ya de sus usuarios de sistema. La guía de
Redis 7 crea el usuario `redis` cuando instala desde fuentes.

```bash
mountpoint /mnt/db_data
getent passwd postgres
getent passwd redis
sudo install -d -o postgres -g postgres -m 0700 /mnt/db_data/postgres
sudo install -d -o redis -g redis -m 0700 /mnt/db_data/redis
sudo stat -c '%U:%G %a %n' /mnt/db_data/postgres /mnt/db_data/redis
df -h /mnt/db_data
```

`install -d` crea directorios; no traslada el contenido de un clúster existente.
La migración de datos se explica en las guías de cada motor. Los archivos de
PostgreSQL deben seguir siendo propiedad de `postgres` y los de Redis, de
`redis`; no asignes todo el disco a un solo usuario recursivamente.

## 1850 GB para PostgreSQL y 150 GB para Redis

Dos carpetas no crean límites de espacio. En un filesystem compartido estos
valores son **objetivos de capacidad**, no reservas. Además 1850 + 150 =
2000 GB y no deja espacio para metadatos ni mantenimiento: no se debe llenar
el disco hasta esa suma. Vigila el volumen total y activa alertas antes del
80 % y 90 % de ocupación; conserva margen adicional para WAL y reescrituras.

Si necesitas cuotas estrictas, diseña antes volúmenes LVM separados o cuotas
de proyecto del filesystem concreto. Eso depende de cómo se particionó el
disco; no es seguro generar comandos de reducción o formateo sin el inventario.
Los 150 GB de disco de Redis guardan AOF/RDB; no aumentan su capacidad en RAM.

## Orden al arrancar y al recuperar

Ambos servicios deben incluir `RequiresMountsFor=/mnt/db_data` para fallar si
el disco no está disponible, en lugar de escribir silenciosamente en el SO.
Después de cualquier cambio de fstab, verifica el montaje y los servicios
antes de reiniciar. Guarda respaldos fuera de este disco y fuera del SO.

Referencia: [montajes y dependencias de systemd](https://www.freedesktop.org/software/systemd/man/latest/systemd.mount.html).
