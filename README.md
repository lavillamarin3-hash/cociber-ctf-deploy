# Despliegue nativo de Cociber CTF

Guías, SQL y configuración para **lab-db-ctf**, Ubuntu Server 26.04,
**10.10.10.14/24**, 4 vCPU, 32 GB RAM, disco del SO de 50 GB y disco de datos
de 2 TB. PostgreSQL **16** y Redis **7** se ejecutan como servicios nativos.
La aplicación está en **10.10.10.13/24**; los permisos de red usan su IP `/32`.
El inventario real muestra una raíz LVM de **24G** dentro del disco de SO de
50G y el disco de datos ya montado en `/mnt/db_data`.

Este repositorio contiene el despliegue. El código de la plataforma permanece
en [ctf-platform](https://github.com/lavillamarin3-hash/ctf-platform) y la web del
taller en [operacion-condor](https://github.com/lavillamarin3-hash/operacion-condor).

## Orden de trabajo

**El SO y el disco ya están preparados:** comienza por
[Continuar la instalación desde el estado real](docs/07_CONTINUAR_INSTALACION.md).
El disco ya está montado en `/mnt/db_data`; no se formatea ni se vuelve a montar.

0. [Preparar las credenciales privadas](docs/00_CREDENCIALES_Y_PREPARACION.md).
1. [Verificar el almacenamiento ya preparado](docs/01_SERVIDOR_Y_ALMACENAMIENTO.md).
2. [Instalar y configurar PostgreSQL 16](docs/02_POSTGRESQL_16.md).
3. [Instalar y configurar Redis 7](docs/03_REDIS_7.md).
4. [Crear el esquema de la plataforma](docs/04_ESQUEMA_BASE_DATOS.md).
5. [Conectar la aplicación y migrar datos existentes](docs/05_APLICACION_Y_MIGRACION.md).
6. [Comprobaciones de aceptación y respaldo](docs/06_ACEPTACION_Y_RESPALDO.md).
   - [Scripts de respaldo Docker y base nativa](docs/09_RESPALDOS_POSTGRES_REDIS.md).
7. [Víctima web LAB-SRVWEB y guía de Operación Cóndor](docs/08_LAB_SRVWEB_CONDOR.md).

Consulta las [pruebas de esta entrega y su alcance](VALIDACION.md).

## Actualizar una copia anterior de estas guías

Las guías vigentes están en las mismas rutas `docs/00` a `docs/06`. Utiliza
estas versiones para continuar desde el servidor ya preparado. `docs/07` es
el resumen del procedimiento y `docs/08` enlaza el despliegue de la víctima web.

Si ya clonaste el repositorio en el servidor, comprueba su origen y sus cambios
antes de actualizar; omite los comandos `git clone` de la instalación inicial:

```bash
sudo git -C /opt/cociber-ctf-deploy remote get-url origin
sudo git -C /opt/cociber-ctf-deploy status --short
sudo git -C /opt/cociber-ctf-deploy pull --ff-only origin main
```

El origen debe ser `https://github.com/lavillamarin3-hash/cociber-ctf-deploy.git`.
Si hay cambios propios o Git no puede avanzar directamente, revísalos antes de
continuar. Actualizar el repositorio no ejecuta instaladores ni modifica las
bases de datos o el archivo privado en `/etc/cociber-ctf`.

Los scripts de configuración ofrecen comprobación previa y requieren una
acción explícita para aplicar cambios. No formatean discos. El SQL inicial
es para una **base nueva y vacía**; para conservar la instalación actual se
utiliza un respaldo y restauración, no se ejecuta otra inicialización encima.

## Credenciales

El administrador de ambos motores se llama **cociberctf**. PostgreSQL utiliza
un rol `LOGIN SUPERUSER`; Redis utiliza un usuario ACL administrativo, no una
tabla SQL. Los comandos leen las contraseñas del archivo privado
`/etc/cociber-ctf/deploy-secrets.env`. `.env.example` solo es una plantilla.
La guía privada entregada al propietario incluye las credenciales solicitadas.
Los archivos privados están excluidos de Git.

## Memoria y espacio

`effective_cache_size=20GB` es una estimación del planificador, no una reserva
ni un límite del proceso. `work_mem` se aplica por operación y por sesión.
`maxmemory 8gb` limita los datos administrados por Redis, pero el proceso y los
forks de persistencia consumen memoria adicional. Por eso el reparto nominal
20/8/4 GB no garantiza evitar OOM: las guías incluyen límites, concurrencia,
medición y margen de mantenimiento.

Las carpetas de PostgreSQL y Redis comparten el disco montado en
`/mnt/db_data`. Los objetivos de 1850 GB y 150 GB no son cuotas automáticas:
se debe reservar espacio para metadatos, WAL, archivos temporales y reescritura
AOF. La guía distingue una distribución lógica de un límite físico real.

## Alcance de la entrega

Los comandos se preparan para las IP y versiones indicadas. Su validación en
pruebas aisladas se registra por separado; ejecutar estas guías en el servidor
y comprobar su arranque después de un reinicio sigue siendo una actividad del
despliegue real. No se presupone que el servidor ya haya sido modificado.
