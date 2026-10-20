\set ON_ERROR_STOP on
-- OPTIONAL reference rows, deliberately separate from the empty schema.
-- These are application role labels, not PostgreSQL roles or login accounts.
BEGIN;
DO $guard$
BEGIN
    IF current_database() <> 'cociber_ctf' THEN
        RAISE EXCEPTION 'Expected database cociber_ctf';
    END IF;
    IF EXISTS (SELECT 1 FROM public.roles) THEN
        RAISE EXCEPTION 'roles is not empty; inspect existing application labels';
    END IF;
END
$guard$;
INSERT INTO public.roles (name, description) VALUES
    ('admin', 'Administración completa de la plataforma'),
    ('instructor', 'Diseño y seguimiento de retos'),
    ('player', 'Participante de retos'),
    ('guest', 'Consulta de solo lectura');
COMMIT;
