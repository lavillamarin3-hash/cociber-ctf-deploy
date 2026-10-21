\set ON_ERROR_STOP on
\set ECHO none
-- Run once as the local PostgreSQL administrator, connected to cociber_ctf.
-- Does not create or alter any application tables or application users.
\getenv app_password PG_APP_PASSWORD
\if :{?app_password}
\else
    \echo 'Falta PG_APP_PASSWORD en el entorno privado.'
    \quit 1
\endif
BEGIN;
SET LOCAL log_statement = 'none';
SET LOCAL log_min_error_statement = 'panic';
SET LOCAL password_encryption = 'scram-sha-256';
SELECT length(:'app_password') >= 20
    AND upper(btrim(:'app_password')) !~ '^(REEMPLAZAR|GENERAR|CHANGE_ME|CHANGEME|REPLACE_ME|YOUR_)'
    AS password_valid \gset
\if :password_valid
\else
    \echo 'PG_APP_PASSWORD debe ser privada, sin marcador de plantilla y con al menos 20 caracteres.'
    \quit 1
\endif

DO $guard$
BEGIN
    IF current_database() <> 'cociber_ctf' THEN
        RAISE EXCEPTION 'Expected database cociber_ctf';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = current_user AND rolsuper) THEN
        RAISE EXCEPTION 'Run this provisioning script as a PostgreSQL superuser';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'cociber_app') THEN
        RAISE EXCEPTION 'Role cociber_app already exists; no credential was changed';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_tables WHERE schemaname = 'public' AND tablename = 'users') THEN
        RAISE EXCEPTION 'Apply 01_schema.sql before granting runtime access';
    END IF;
END
$guard$;
SELECT format(
    'CREATE ROLE %I LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION NOBYPASSRLS PASSWORD %L',
    'cociber_app', :'app_password'
) \gexec

REVOKE ALL ON DATABASE cociber_ctf FROM PUBLIC;
GRANT CONNECT ON DATABASE cociber_ctf TO cociber_app;
REVOKE ALL ON SCHEMA public FROM PUBLIC;
GRANT USAGE ON SCHEMA public TO cociber_app;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO cociber_app;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO cociber_app;
ALTER DEFAULT PRIVILEGES FOR ROLE cociberctf IN SCHEMA public
    GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO cociber_app;
ALTER DEFAULT PRIVILEGES FOR ROLE cociberctf IN SCHEMA public
    GRANT USAGE, SELECT ON SEQUENCES TO cociber_app;
COMMIT;
\unset app_password
\unset password_valid
