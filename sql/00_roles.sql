\set ON_ERROR_STOP on
\set ECHO none
-- Run once as the local PostgreSQL administrator, connected to postgres.
-- Password is read from the private process environment, never from this file.
\getenv admin_password PG_ADMIN_PASSWORD
\if :{?admin_password}
\else
    \echo 'Falta PG_ADMIN_PASSWORD en el entorno privado.'
    \quit 1
\endif
BEGIN;
SET LOCAL log_statement = 'none';
SET LOCAL log_min_error_statement = 'panic';
SET LOCAL password_encryption = 'scram-sha-256';
SELECT length(:'admin_password') >= 12
    AND upper(btrim(:'admin_password')) !~ '^(REEMPLAZAR|GENERAR|CHANGE_ME|CHANGEME|REPLACE_ME|YOUR_)'
    AS password_valid \gset
\if :password_valid
\else
    \echo 'PG_ADMIN_PASSWORD debe ser privada, sin marcador de plantilla y con al menos 12 caracteres.'
    \quit 1
\endif

DO $guard$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = current_user AND rolsuper) THEN
        RAISE EXCEPTION 'Run this provisioning script as a PostgreSQL superuser';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'cociberctf') THEN
        RAISE EXCEPTION 'Role cociberctf already exists; inspect it before a reviewed migration';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_catalog.pg_database WHERE datname = 'cociber_ctf') THEN
        RAISE EXCEPTION 'Database cociber_ctf already exists; do not run fresh provisioning';
    END IF;
END
$guard$;
-- The requested administrative account is intentionally a SUPERUSER.
-- The API uses the separate non-superuser account from 02_runtime.sql.
SELECT format('CREATE ROLE %I LOGIN SUPERUSER PASSWORD %L', 'cociberctf', :'admin_password') \gexec
COMMIT;

-- CREATE DATABASE must run outside a transaction in PostgreSQL.
CREATE DATABASE cociber_ctf OWNER cociberctf ENCODING 'UTF8' TEMPLATE template0;
REVOKE ALL ON DATABASE cociber_ctf FROM PUBLIC;
\unset admin_password
\unset password_valid
