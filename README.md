# Despliegue nativo de Cociber CTF

Guías, SQL y configuración para **LAB-DB-POSTGRES**, Ubuntu Server 26.04,
**10.10.10.14/24**, 4 vCPU, 32 GB RAM, disco del SO de 50 GB y disco de datos
de 2 TB. PostgreSQL **16** y Redis **7** se ejecutan como servicios nativos.
La aplicación está en **10.10.10.13/24**; los permisos de red usan su IP `/32`.

Este repositorio contiene el despliegue. El código de la plataforma permanece
en [ctf-platform](https://github.com/lavillamarin3-hash/ctf-platform) y la web del
taller en [operacion-condor](https://github.com/lavillamarin3-hash/operacion-condor).

## Orden de trabajo

0. [Preparar las credenciales privadas](docs/00_CREDENCIALES_Y_PREPARACION.md).
1. [Preparar almacenamiento y verificar recursos](docs/01_SERVIDOR_Y_ALMACENAMIENTO.md).
2. [Instalar y configurar PostgreSQL 16](docs/02_POSTGRESQL_16.md).
3. [Instalar y configurar Redis 7](docs/03_REDIS_7.md).
4. [Crear el esquema de la plataforma](docs/04_ESQUEMA_BASE_DATOS.md).
5. [Conectar la aplicación y migrar datos existentes](docs/05_APLICACION_Y_MIGRACION.md).
6. [Comprobaciones de aceptación y respaldo](docs/06_ACEPTACION_Y_RESPALDO.md).

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
