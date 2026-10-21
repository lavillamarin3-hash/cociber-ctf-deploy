# Víctima web: LAB-SRVWEB

La aplicación del taller tiene su propio repositorio y su
[guía completa de despliegue de LAB-SRVWEB](https://github.com/lavillamarin3-hash/operacion-condor/blob/main/GUIA_LAB_SRVWEB.md).

| Componente | Destino |
|---|---|
| Web víctima | Ubuntu 26.04, LAB-SRVWEB, `10.10.30.20/24` |
| Recursos | 2 GiB RAM, disco 20 GiB |
| Alumnos / Kali | VLAN 20, `10.10.20.0/24` |
| Acceso entre VLAN | Kali → `10.10.30.20`, TCP 8080 y retorno |
| Aplicación web | Nginx → Gunicorn local, SQLite local |
| Plataforma Cociber | `10.10.10.13` → bases `10.10.10.14` |

La víctima no necesita credenciales de las bases de Cociber ni acceso a ellas.
El tráfico del taller se permite entre VLAN 20 y esa víctima específica; la
administración SSH usa el origen autorizado por el responsable del laboratorio.
El instalador admite redes cliente y servidor diferentes y no configura rutas
ni ACL del router. El despliegue real de esa VM y la prueba desde Kali están
pendientes de ejecutar los comandos en el servidor.
