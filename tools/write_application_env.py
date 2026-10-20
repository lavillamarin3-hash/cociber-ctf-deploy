"""Write connection lines privately, with percent-encoded passwords."""
import argparse
import os
from pathlib import Path
import sys
from urllib.parse import quote
from private_env import read_private_env


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--secrets-file', default='/etc/cociber-ctf/deploy-secrets.env')
    parser.add_argument('--output', required=True)
    parser.add_argument('--pg-ssl', choices=['require', 'verify-full'], default='require')
    args = parser.parse_args()
    values = read_private_env(args.secrets_file)
    prefix = 'APP'
    for key in ('PG_'+prefix+'_PASSWORD', 'REDIS_'+prefix+'_PASSWORD'):
        if not values.get(key):
            raise ValueError('Falta una credencial requerida en el archivo privado.')
    pg_user = 'cociber_app'
    redis_user = pg_user
    pg_pass = quote(values['PG_'+prefix+'_PASSWORD'], safe='')
    redis_pass = quote(values['REDIS_'+prefix+'_PASSWORD'], safe='')
    content = (f"DATABASE_URL='postgresql+asyncpg://{pg_user}:{pg_pass}@10.10.10.14:5432/cociber_ctf?ssl={args.pg_ssl}'\n"
               f"REDIS_URL='redis://{redis_user}:{redis_pass}@10.10.10.14:6379/0'\n"
               "MANAGE_SCHEMA_ON_STARTUP=false\nCTF_SEED_DEMO_DATA=false\n")
    target = Path(args.output)
    if target.exists() or target.is_symlink():
        raise ValueError('El destino ya existe; no se reemplazará un archivo de configuración.')
    if not target.parent.is_dir():
        raise ValueError('Crea primero el directorio privado de destino.')
    descriptor = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, 'w', encoding='utf-8', newline='\n') as stream:
        stream.write(content)
    print('Archivo privado de conexión creado; no se imprimieron sus valores.')


if __name__ == '__main__':
    try:
        main()
    except ValueError as error:
        print(str(error), file=sys.stderr)
        raise SystemExit(1)
