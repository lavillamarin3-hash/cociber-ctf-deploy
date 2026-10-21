# 1. Almacenamiento ya preparado en lab-db-ctf

Actualizado con la salida del operador. El SO, el filesystem y las carpetas ya
están preparados. Continúa con la instalación de PostgreSQL 16 y Redis 7;
no repitas el formateo, el montaje ni la creación de subcarpetas.

| Recurso observado | Estado |
|---|---|
| Hostname real | `lab-db-ctf` |
| Sistema | Ubuntu 26.04 LTS, resolute, x86-64 |
| Interfaz / IP | `ens3`, `10.10.10.14/24` |
| CPU / RAM | 4 vCPU, aproximadamente 30 GiB visibles |
| SO | Disco de 50G; **raíz LVM de 24G**, con aproximadamente 15G libres |
| Datos | `/dev/sdb`, 2T, ext4, montado en `/mnt/db_data` |
| UUID de datos | `a5a1988e-6d34-4c4f-ab0a-a97d40cf6e39` |
| Carpetas creadas | `/mnt/db_data/postgres`, `/mnt/db_data/redis` |
| fstab actual | `/dev/sdb /mnt/db_data ext4 defaults,noatime 0 2` |
| PostgreSQL | `pg_lsclusters` aún no instalado |
| API autorizada | `10.10.10.13/32` |

## Comprobación de lectura

En **lab-db-ctf**:

```bash
findmnt --mountpoint /mnt/db_data -o SOURCE,TARGET,FSTYPE,OPTIONS
sudo blkid /dev/sdb
df -hT / /mnt/db_data
sudo ls -ld /mnt/db_data /mnt/db_data/postgres /mnt/db_data/redis
sudo find /mnt/db_data/postgres /mnt/db_data/redis -mindepth 1 -maxdepth 1 -print
```

Confirma el UUID y el montaje del disco de datos. Las subcarpetas deben estar
vacías para inicializar motores nuevos. Si contienen datos, utiliza migración
y respaldo. Si el montaje no aparece, detente antes de instalar: una carpeta
sin ese disco podría llenar la raíz de 24G.

No ejecutes `mkfs` de nuevo. No necesitas un bind desde
`/var/lib/postgresql`, otro montaje ni cambiar el hostname a LAB-DB-POSTGRES;
ese era el nombre previsto, pero el nombre real es `lab-db-ctf`.

## Mejorar la persistencia del montaje

La línea actual funciona. Es preferible identificar el mismo filesystem por
UUID para evitar cambios en el orden de discos. Comprueba primero que `blkid`
devuelve el UUID del inventario; después respalda fstab:

```bash
sudo cp -a /etc/fstab "/etc/fstab.cociber.$(date -u +%Y%m%dT%H%M%SZ).bak"
sudoedit /etc/fstab
```

**Sustituye la línea existente** de `/dev/sdb /mnt/db_data` por la siguiente;
no añadas una segunda línea para el mismo destino:

```fstab
UUID=a5a1988e-6d34-4c4f-ab0a-a97d40cf6e39 /mnt/db_data ext4 defaults,noatime 0 2
```

```bash
sudo findmnt --verify --verbose
sudo systemctl daemon-reload
findmnt --mountpoint /mnt/db_data
```

No hace falta desmontar ni formatear. Corrige cualquier error antes de un
reinicio. Los servicios dependen de este montaje y no usan `nofail`.

## Propietarios después de instalar los usuarios de servicio

Las carpetas creadas con `mkdir` pueden pertenecer aún a root. Los pasos de
PostgreSQL instalarán `postgres`; el instalador Redis creará `redis`.
Cada procedimiento asigna solo su subcarpeta:

- PostgreSQL: `postgres:postgres`, modo `0700`.
- Redis: `redis:redis`, modo `0750`.
- Padre `/mnt/db_data`: modo `0755` para permitir el recorrido.

No asignes recursivamente todo el disco a un motor ni crees cuentas manuales
antes de seguir sus instaladores.

## Capacidad y arranque

1850 GB para PostgreSQL y 150 GB para Redis son objetivos, no cuotas de estas
carpetas. Conserva margen para ext4, WAL, temporales y reescrituras AOF. La
capacidad disponible real es la que indique `df`; no se cambia el particionado.

Guarda respaldos completos fuera del disco de datos y de la raíz de 24G.
Ambos servicios incluyen dependencias de montaje para evitar escribir en el
SO si falta el volumen. El reinicio se valida en la aceptación.

Continúa con [el orden de instalación desde el estado actual](07_CONTINUAR_INSTALACION.md)
y [PostgreSQL 16](02_POSTGRESQL_16.md).
Referencia: [montajes y dependencias de systemd](https://www.freedesktop.org/software/systemd/man/latest/systemd.mount.html).
