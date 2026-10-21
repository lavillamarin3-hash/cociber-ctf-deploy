# Validación de la entrega

Revisión final: **21 de octubre de 2026**. Estas pruebas no modificaron los
servidores del laboratorio.

- **8 pruebas unitarias aprobadas:** lectura literal de secretos, rechazo de
  plantillas/archivos inválidos, codificación de URL, protección contra
  sobrescritura y verificación del cluster nativo correcto antes de provisionar.
- **PostgreSQL 16 aislado:** creación de las 19 tablas reales, roles administrativos
  y de ejecución, DML/secuencias, rechazo de DDL, unicidad, claves foráneas y
  rechazo de una segunda inicialización conservando filas y 100 puntos de QA.
- **Redis 7.4.11 aislado:** autenticación, ACL administrativa y de aplicación,
  SELECT, SET/GET, Lua, Pub/Sub real, denegaciones administrativas y de canales,
  configuración de 8gb y noeviction. Sin puertos publicados ni red externa.
- SQL y diccionario comparados con el ORM y compatibilidad de la plataforma;
  los dos índices adicionales están incluidos.
- Sintaxis de instaladores Bash comprobada en Linux. Las pruebas de motores
  usan contenedores temporales propios para validación; los instaladores
  entregados ejecutan servicios **nativos** en Ubuntu.

Los contenedores QA se eliminaron verificando su identidad. Las contraseñas de
las pruebas son sintéticas y no son las del archivo privado del propietario.

Queda por ejecutar en las VMs: instalación nativa, permisos de disco reales,
red/firewall, conexión de la API, migración de datos si corresponde, medición de
memoria bajo carga, respaldo/restauración y arranque después de reiniciar.
No se declara desplegado el servidor por haber aprobado estas pruebas locales.

## Repetir las verificaciones

```bash
python3 -m unittest discover -s tests -p 'test_*.py' -v
python3 tests/smoke_postgresql.py --run
python3 tests/smoke_redis.py --run
```

Los smoke necesitan Docker únicamente en el equipo de pruebas y las imágenes
locales `postgres:16-alpine` y `redis:7-alpine`. No ejecutan los instaladores en
el host. `tools/generate_schema.py --check` necesita SQLAlchemy y los archivos
de modelos de la plataforma, según la guía del esquema.
