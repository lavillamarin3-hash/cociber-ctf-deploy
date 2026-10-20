"""Read a root-owned env file as data, without sourcing or printing secrets."""
from pathlib import Path
import os
import re
import shlex
import stat


def is_password_placeholder(value):
    normalized = value.strip().upper()
    return (normalized.startswith(('REEMPLAZAR_', 'GENERAR_'))
            or normalized in {'CHANGE_ME', 'CHANGEME', 'REPLACE_ME'})


def read_private_env(filename, *, require_root=True):
    path = Path(filename)
    if path.is_symlink() or not path.is_file():
        raise ValueError('El archivo privado debe ser regular y no ser un enlace.')
    metadata = path.stat()
    if os.name != 'nt':
        if require_root and (os.geteuid() != 0 or metadata.st_uid != 0):
            raise ValueError('Ejecuta como root y usa un archivo privado propiedad de root.')
        if stat.S_IMODE(metadata.st_mode) & 0o077:
            raise ValueError('El archivo privado requiere permisos 0600 o más restrictivos.')
    result = {}
    for number, raw in enumerate(path.read_text(encoding='utf-8-sig').splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith('#'):
            continue
        key, separator, value = line.partition('=')
        if not separator or not re.fullmatch(r'[A-Z][A-Z0-9_]*', key):
            raise ValueError(f'Formato inválido en la línea {number}; no se ejecutó el archivo.')
        parts = shlex.split(value, comments=True, posix=True)
        if len(parts) != 1 or any(ord(char) < 32 for char in parts[0]):
            raise ValueError(f'Valor inválido en la línea {number}; usa comillas simples.')
        if key in result:
            raise ValueError(f'Clave repetida en la línea {number}.')
        if (key == 'PASSWORD' or key.endswith('_PASSWORD')) and is_password_placeholder(parts[0]):
            raise ValueError(f'Contraseña de plantilla en la línea {number}; configura un valor privado antes de continuar.')
        result[key] = parts[0]
    return result
