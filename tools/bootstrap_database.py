"""Provision a NEW database through local peer auth, without secret argv."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
from private_env import read_private_env


def validate_cluster_identity(identity):
    """Rechaza otro cluster antes de ejecutar cualquier archivo SQL."""
    if not isinstance(identity, dict):
        raise ValueError('No se pudo comprobar la identidad del cluster PostgreSQL.')
    try:
        version = int(identity['version'])
        port = int(identity['port'])
    except (KeyError, TypeError, ValueError):
        raise ValueError('No se pudo comprobar la identidad del cluster PostgreSQL.') from None
    if not 160000 <= version < 170000:
        raise ValueError('El servidor conectado debe ser PostgreSQL 16.')
    if (port != 5432 or identity.get('data_directory') != '/mnt/db_data/postgres'
            or identity.get('config_file') != '/etc/postgresql/16/main/postgresql.conf'):
        raise ValueError('El servidor no corresponde a 16/main en /mnt/db_data/postgres, puerto 5432; no se ejecutó SQL de instalación.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--secrets-file', default='/etc/cociber-ctf/deploy-secrets.env')
    parser.add_argument('--apply', action='store_true')
    parser.add_argument('--runtime', action='store_true', help='Crear también cociber_app.')
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument('--roles-only', action='store_true', help='Preparar únicamente rol y base vacía para restaurar un dump completo.')
    mode.add_argument('--runtime-only', action='store_true', help='Conceder permisos a cociber_app después de restaurar, sin crear esquema.')
    args = parser.parse_args()
    if args.roles_only and args.runtime:
        raise ValueError('--roles-only no se combina con --runtime; restaura primero y usa después --runtime-only.')
    needs_runtime = args.runtime or args.runtime_only
    if os.name == 'nt' or os.geteuid() != 0:
        raise ValueError('Este aprovisionamiento se ejecuta con sudo en Ubuntu, no en Windows.')
    values = read_private_env(args.secrets_file)
    if len(values.get('PG_ADMIN_PASSWORD', '')) < 12:
        raise ValueError('Falta PG_ADMIN_PASSWORD válido en el archivo privado.')
    if needs_runtime and len(values.get('PG_APP_PASSWORD', '')) < 20:
        raise ValueError('La cuenta de ejecución requiere PG_APP_PASSWORD privado de al menos 20 caracteres.')
    environment = {'PATH': '/usr/sbin:/usr/bin:/sbin:/bin', 'LANG': 'C.UTF-8',
                   'PG_ADMIN_PASSWORD': values['PG_ADMIN_PASSWORD']}
    if needs_runtime:
        environment['PG_APP_PASSWORD'] = values['PG_APP_PASSWORD']
    base = Path(__file__).resolve().parents[1]
    binary = '/usr/lib/postgresql/16/bin/psql'

    def psql(database, *, sql=None, filename=None):
        command = ['runuser', '-u', 'postgres', '--', binary, '-X', '--no-password',
                   '-h', '/var/run/postgresql', '-p', '5432',
                   '-v', 'ON_ERROR_STOP=1', '-U', 'postgres', '-d', database]
        command += ['-At', '-c', sql] if sql is not None else ['-f', str(filename)]
        result = subprocess.run(command, env=environment, text=True, capture_output=True)
        if result.returncode:
            # Do not echo SQL errors: a role statement can contain its password.
            raise RuntimeError('Falló PostgreSQL. No se imprimió SQL ni credenciales; revisa el estado antes de continuar.')
        return result.stdout.strip()

    identity_raw = psql('postgres', sql="SELECT json_build_object("
        "'version', current_setting('server_version_num'), "
        "'port', current_setting('port'), "
        "'data_directory', current_setting('data_directory'), "
        "'config_file', current_setting('config_file'))::text")
    try:
        identity = json.loads(identity_raw)
    except (TypeError, json.JSONDecodeError):
        raise ValueError('No se pudo comprobar la identidad del cluster PostgreSQL.') from None
    validate_cluster_identity(identity)
    if args.runtime_only:
        restored = psql('cociber_ctf', sql="SELECT to_regclass('public.users') IS NOT NULL AND NOT EXISTS(SELECT 1 FROM pg_roles WHERE rolname='cociber_app')")
        if restored != 't':
            raise ValueError('Se requiere la base restaurada y un rol cociber_app todavía inexistente; revisa los permisos si ya existe.')
        scripts = [('cociber_ctf', '02_runtime.sql')]
    else:
        existing = psql('postgres', sql="SELECT EXISTS(SELECT 1 FROM pg_roles WHERE rolname='cociberctf') OR EXISTS(SELECT 1 FROM pg_database WHERE datname='cociber_ctf')")
        if existing != 'f':
            raise ValueError('El rol o la base ya existen: usa migración/restauración revisada, no inicialización nueva.')
        scripts = [('postgres', '00_roles.sql')]
        if not args.roles_only:
            scripts += [('cociber_ctf', '01_schema.sql'), ('cociber_ctf', '03_bootstrap_roles.sql')]
            if args.runtime:
                scripts.append(('cociber_ctf', '02_runtime.sql'))
    for _, filename in scripts:
        path = base/'sql'/filename
        if path.is_symlink() or not path.is_file():
            raise ValueError('Falta un archivo SQL regular requerido por el aprovisionamiento.')
    if not args.apply:
        print('Comprobado: cluster PostgreSQL 16, destino del modo elegido, SQL y archivo privado válidos. Añade --apply para ejecutar.')
        return
    for database, filename in scripts:
        psql(database, filename=base/'sql'/filename)
        print('Aplicado: ' + filename)
    print('Modo completado. No se crearon usuarios web ni se copiaron datos del laboratorio.')


if __name__ == '__main__':
    try:
        main()
    except (ValueError, RuntimeError) as error:
        print(str(error), file=sys.stderr)
        raise SystemExit(1)
