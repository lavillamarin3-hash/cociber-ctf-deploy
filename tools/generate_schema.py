#!/usr/bin/env python3
"""Compile the platform ORM into empty PostgreSQL DDL, without a DB connection.

Requires the platform's pinned SQLAlchemy dependency. Imports only models.py,
never application settings, a session factory, .env files or seed routines.
"""

import argparse
import hashlib
import importlib.util
import re
from pathlib import Path
import sys

from sqlalchemy import UniqueConstraint
from sqlalchemy.dialects import postgresql
from sqlalchemy.schema import CreateIndex, CreateTable
from sqlalchemy.util import OrderedSet


DICTIONARY_MARKER = "<!-- BEGIN GENERATED ORM DICTIONARY -->"


PREFIX = r"""\set ON_ERROR_STOP on
-- Fresh installation only. No application rows, passwords or destructive DDL.
-- Run using psql against cociber_ctf after sql/00_roles.sql.
BEGIN;
SET LOCAL ROLE cociberctf;
SET LOCAL search_path = public, pg_catalog;
DO $guard$
BEGIN
    IF current_database() <> 'cociber_ctf' THEN
        RAISE EXCEPTION 'Expected database cociber_ctf; no schema was created';
    END IF;
    IF EXISTS (
        SELECT 1 FROM pg_catalog.pg_class c
        JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'public'
          AND c.relkind IN ('r', 'p', 'v', 'm', 'S', 'f', 'i', 'I', 'c')
    ) OR EXISTS (
        SELECT 1 FROM pg_catalog.pg_proc p
        JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'public'
    ) OR EXISTS (
        SELECT 1 FROM pg_catalog.pg_type t
        JOIN pg_catalog.pg_namespace n ON n.oid = t.typnamespace
        WHERE n.nspname = 'public'
    ) THEN
        RAISE EXCEPTION 'public is not empty; use a reviewed migration or backup restore';
    END IF;
END
$guard$;
"""


def load_metadata(path):
    spec = importlib.util.spec_from_file_location("cociber_schema_models", path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module.Base.metadata


def constraint_order(constraint):
    return (
        type(constraint).__name__, constraint.name or "",
        ",".join(column.name for column in getattr(constraint, "columns", [])),
        str(getattr(constraint, "sqltext", "")),
    )


def compile_schema(models_path, compatibility_path):
    metadata = load_metadata(models_path)
    dialect = postgresql.dialect()
    sections = [
        PREFIX.rstrip(),
        "-- Generated from backend/app/models.py; SHA-256: " + hashlib.sha256(models_path.read_bytes()).hexdigest(),
        "-- Compatibility source backend/app/db.py; SHA-256: " + hashlib.sha256(compatibility_path.read_bytes()).hexdigest(),
        f"-- ORM tables: {len(metadata.tables)}",
    ]
    existing_names = set()
    for table in metadata.sorted_tables:
        # SQLAlchemy stores constraints as a set; normalize order for reproducibility.
        table.constraints = OrderedSet(sorted(table.constraints, key=constraint_order))
        sections.append(str(CreateTable(table).compile(dialect=dialect)).strip() + ";")
        for constraint in table.constraints:
            if isinstance(constraint, UniqueConstraint) and constraint.name:
                existing_names.add(constraint.name)
        for index in sorted(table.indexes, key=lambda item: item.name):
            existing_names.add(index.name)
            sections.append(str(CreateIndex(index).compile(dialect=dialect)).strip() + ";")

    # create_schema adds two partial unique indexes beyond the ORM. The other
    # compatibility indexes already exist in metadata (or back a named UNIQUE).
    compatibility = compatibility_path.read_text(encoding="utf-8")
    additions = re.findall(
        r"CREATE\s+(?:UNIQUE\s+)?INDEX\s+IF\s+NOT\s+EXISTS\s+\w+\s+ON\s+\w+\s*\([^)]*\)(?:\s+WHERE\s+[^\"\n]*)?",
        compatibility, flags=re.IGNORECASE,
    )
    extra_indexes = []
    for statement in additions:
        name = re.search(r"EXISTS\s+(\w+)", statement, flags=re.IGNORECASE).group(1)
        if name in existing_names:
            continue
        table_name = re.search(r"\bON\s+(\w+)", statement, flags=re.IGNORECASE).group(1)
        if table_name not in metadata.tables:
            raise RuntimeError(f"Compatibility index references unknown ORM table: {table_name}")
        normalized = re.sub(r"\s+IF\s+NOT\s+EXISTS", "", statement, flags=re.IGNORECASE).strip().rstrip(";")
        extra_indexes.append((name, normalized + ";"))
        existing_names.add(name)
    if extra_indexes:
        sections.append("-- Additional indexes applied by app.db.create_schema on a fresh installation.")
        sections.extend(statement for _name, statement in sorted(extra_indexes))
    sections.append("COMMIT;")
    schema = "\n".join(line.rstrip() for line in "\n\n".join(sections).splitlines()) + "\n"
    return schema, sorted(metadata.tables), [name for name, _statement in sorted(extra_indexes)]


def dictionary_text(models_path):
    metadata = load_metadata(models_path)
    dialect = postgresql.dialect()
    output = ["## Diccionario de columnas", "", "Generado desde el mismo ORM que el SQL. `Python` indica un valor aplicado por SQLAlchemy; no es un `DEFAULT` del servidor.", ""]
    for table in sorted(metadata.tables.values(), key=lambda item: item.name):
        output.extend([f"### `{table.name}`", "", "| Campo | PostgreSQL | NULL | Predeterminado | Claves y relaciones |", "|---|---|---|---|---|"])
        for column in table.columns:
            keys = []
            if column.primary_key:
                keys.append("PK; SERIAL")
            if column.unique:
                keys.append("UNIQUE")
            for foreign_key in sorted(column.foreign_keys, key=lambda item: item.target_fullname):
                keys.append(f"FK → `{foreign_key.target_fullname}`; DELETE {foreign_key.ondelete or 'NO ACTION'}")
            default = "—"
            if column.server_default is not None:
                default = f"`{column.server_default.arg}` (servidor)"
            elif column.default is not None:
                argument = column.default.arg
                value = getattr(argument, "__name__", "función") + "()" if callable(argument) else repr(argument)
                default = f"`{value}` (Python)"
            output.append(f"| `{column.name}` | `{column.type.compile(dialect=dialect)}` | {'Sí' if column.nullable else 'No'} | {default} | {'; '.join(keys) or '—'} |")
        constraints = []
        for constraint in sorted(table.constraints, key=constraint_order):
            if isinstance(constraint, UniqueConstraint):
                constraints.append(f"UNIQUE ({', '.join(column.name for column in constraint.columns)})")
            elif hasattr(constraint, "sqltext"):
                constraints.append(f"{constraint.name}: CHECK ({constraint.sqltext})")
        if constraints:
            output.extend(["", "Restricciones adicionales: " + "; ".join(f"`{value}`" for value in constraints) + "."])
        output.append("")
    return "\n".join(output).rstrip() + "\n"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--models", type=Path, required=True)
    parser.add_argument("--db-compat", type=Path)
    parser.add_argument("--output", type=Path, default=Path(__file__).resolve().parent.parent / "sql/01_schema.sql")
    parser.add_argument("--check", action="store_true", help="Compare the generated file without writing")
    parser.add_argument("--dictionary-output", type=Path, help="Update only the generated section of the Markdown dictionary")
    args = parser.parse_args()
    compatibility = args.db_compat or args.models.with_name("db.py")
    schema, tables, extras = compile_schema(args.models, compatibility)
    if args.check:
        if not args.output.is_file() or args.output.read_text(encoding="utf-8") != schema:
            print("Schema differs from the selected ORM/compatibility source", file=sys.stderr)
            return 1
    else:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(schema, encoding="utf-8", newline="\n")
    if args.dictionary_output:
        current = args.dictionary_output.read_text(encoding="utf-8") if args.dictionary_output.exists() else ""
        prefix = current.split(DICTIONARY_MARKER, 1)[0].rstrip()
        expected = prefix + "\n\n" + DICTIONARY_MARKER + "\n\n" + dictionary_text(args.models)
        if args.check:
            if current != expected:
                print("Dictionary differs from selected ORM source", file=sys.stderr)
                return 1
        else:
            args.dictionary_output.parent.mkdir(parents=True, exist_ok=True)
            args.dictionary_output.write_text(expected, encoding="utf-8", newline="\n")
    print(f"Tables ({len(tables)}): " + ", ".join(tables), file=sys.stderr)
    print("Additional compatibility indexes: " + ", ".join(extras), file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
