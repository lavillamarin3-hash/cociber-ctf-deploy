#!/usr/bin/env python3
"""Opt-in smoke test against an expendable, isolated PostgreSQL 16 container.

This never connects to the deployment, reads a private env file or publishes a
host port. It uses only synthetic credentials, a UUID-labelled container, a
read-only SQL bind mount and an in-memory data directory. Requires explicit
--run; the cached postgres:16-alpine image is never pulled over the network.
"""

import argparse
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import subprocess
import sys
import time
import uuid


TABLES = {
    "audit_events", "challenge_completions", "challenge_flags",
    "challenge_group_assignments", "challenge_hint_reveals", "challenge_instances",
    "challenge_learning_progress", "challenge_run_flags", "challenge_runs",
    "challenges", "group_memberships", "laboratories", "remote_access_assignments",
    "reset_operations", "roles", "student_groups", "submissions", "users", "vm_assets",
}
LABEL = "com.cociber.qa.run"


class SmokeFailure(RuntimeError):
    pass


def command(arguments, *, environment=None, timeout=30):
    return subprocess.run(
        arguments, env=environment, stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
        encoding="utf-8", errors="replace", timeout=timeout,
    )


def require(result, description):
    if result.returncode:
        # Never echo SQL text, Docker environment or generated credentials.
        raise SmokeFailure(f"{description}: exit {result.returncode}")
    return result.stdout.strip()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run", action="store_true", help="Authorize an isolated, disposable Docker QA run")
    parser.add_argument("--sql-dir", type=Path, default=Path(__file__).resolve().parents[1] / "sql")
    args = parser.parse_args()
    if not args.run:
        parser.error("Explicit --run is required; no Docker command was executed")
    docker = shutil.which("docker")
    if not docker:
        parser.error("Docker CLI not found")
    sql_dir = args.sql_dir.resolve()
    for filename in ("00_roles.sql", "01_schema.sql", "02_runtime.sql", "03_bootstrap_roles.sql"):
        if not (sql_dir / filename).is_file():
            parser.error(f"Missing SQL input: {filename}")

    token = uuid.uuid4().hex
    name = "cociber-pg-smoke-" + token
    environment = os.environ.copy()
    environment.update(
        POSTGRES_PASSWORD=secrets.token_urlsafe(32),
        PG_ADMIN_PASSWORD=secrets.token_urlsafe(24),
        PG_APP_PASSWORD=secrets.token_urlsafe(32),
    )
    checks = []
    created = False
    cleanup_ok = True
    failure = None

    def psql(*, database="cociber_ctf", query=None, filename=None, runtime=False):
        invocation = [docker, "exec"]
        execution_environment = environment
        if runtime:
            execution_environment = dict(environment, PGPASSWORD=environment["PG_APP_PASSWORD"])
            invocation.extend(["--env", "PGPASSWORD"])
        invocation.extend([name, "psql", "-X", "--no-psqlrc", "-qAt", "-v", "ON_ERROR_STOP=1", "-v", "VERBOSITY=sqlstate"])
        if runtime:
            invocation.extend(["--host", "127.0.0.1", "--username", "cociber_app"])
        else:
            invocation.extend(["--username", "postgres"])
        invocation.extend(["--dbname", database])
        if query is not None:
            invocation.extend(["--command", query])
        if filename is not None:
            invocation.extend(["--file", "/qa-sql/" + filename])
        return command(invocation, environment=execution_environment)

    def value(query, *, runtime=False):
        return require(psql(query=query, runtime=runtime), "SQL assertion")

    def fingerprint():
        expressions = [
            f"'{table}', (SELECT md5(COALESCE(jsonb_agg(to_jsonb(t) ORDER BY id)::text, '[]')) FROM public.{table} t)"
            for table in sorted(TABLES)
        ]
        return value("SELECT jsonb_build_object(" + ", ".join(expressions) + ")::text")

    try:
        started = command([
            docker, "run", "--detach", "--pull=never", "--name", name,
            "--label", f"{LABEL}={token}", "--network", "none",
            "--tmpfs", "/var/lib/postgresql/data:rw,nosuid,nodev,size=256m",
            "--mount", f"type=bind,source={sql_dir},target=/qa-sql,readonly",
            "--env", "POSTGRES_PASSWORD", "--env", "PG_ADMIN_PASSWORD", "--env", "PG_APP_PASSWORD",
            "postgres:16-alpine",
        ], environment=environment)
        require(started, "Start isolated PostgreSQL container")
        created = True
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            try:
                probe = command(
                    [docker, "exec", name, "pg_isready", "--host", "127.0.0.1", "--username", "postgres", "--dbname", "postgres"],
                    timeout=max(0.1, min(2, deadline - time.monotonic())),
                )
                if probe.returncode == 0:
                    break
            except subprocess.TimeoutExpired:
                pass
            time.sleep(min(0.2, max(0, deadline - time.monotonic())))
        else:
            raise SmokeFailure("PostgreSQL did not become ready within 30 seconds")

        require(psql(database="postgres", filename="00_roles.sql"), "Administrative role/database provisioning")
        require(psql(filename="01_schema.sql"), "Fresh schema installation")
        actual_tables = set(value("SELECT tablename FROM pg_catalog.pg_tables WHERE schemaname='public' ORDER BY tablename").splitlines())
        if actual_tables != TABLES:
            raise SmokeFailure("Fresh schema does not match the expected 19 ORM tables")
        checks.append("19 exact ORM tables")
        if int(value("SELECT count(*) FROM pg_catalog.pg_constraint c JOIN pg_catalog.pg_namespace n ON n.oid=c.connamespace WHERE n.nspname='public' AND c.contype='f'")) == 0:
            raise SmokeFailure("Foreign keys missing")
        if int(value("SELECT count(*) FROM public.users")) != 0:
            raise SmokeFailure("Schema unexpectedly contains application users")
        checks.append("schema initially has no users")

        require(psql(filename="03_bootstrap_roles.sql"), "Optional application role labels")
        if value("SELECT string_agg(name, ',' ORDER BY name) FROM public.roles") != "admin,guest,instructor,player":
            raise SmokeFailure("Application role labels differ")
        require(psql(filename="02_runtime.sql"), "Runtime account provisioning")
        flags = json.loads(value("SELECT json_build_object('admin', (SELECT rolsuper FROM pg_roles WHERE rolname='cociberctf'), 'app', (SELECT rolsuper FROM pg_roles WHERE rolname='cociber_app'))::text"))
        if flags != {"admin": True, "app": False}:
            raise SmokeFailure("Administrative/runtime privileges differ")
        checks.append("administrative SUPERUSER and non-superuser runtime")

        require(psql(runtime=True, query="""
            INSERT INTO public.roles(name,description) VALUES ('qa_temporary','isolated QA');
            UPDATE public.roles SET description='updated QA' WHERE name='qa_temporary';
            DELETE FROM public.roles WHERE name='qa_temporary';
            WITH u AS (
                INSERT INTO public.users(username,password_hash,role,is_active)
                VALUES ('qa_isolated_player','disabled-synthetic-qa-hash','player',true) RETURNING id
            ), c AS (
                INSERT INTO public.challenges(code,name,description,instructions,difficulty,category,mitre_technique,asset_references,points,is_published)
                VALUES ('QA-ISOLATED','Isolated QA','Synthetic QA only','No lab service','easy','MISC','QA','[]',100,false) RETURNING id
            )
            INSERT INTO public.challenge_completions(user_id,challenge_id,awarded_points)
            SELECT u.id,c.id,100 FROM u CROSS JOIN c;
        """), "Runtime insert/update/delete and sequence use")
        if value("SELECT awarded_points FROM public.challenge_completions", runtime=True) != "100":
            raise SmokeFailure("Synthetic completion points differ")
        checks.append("runtime SELECT/INSERT/UPDATE/DELETE and sequences")

        forbidden = psql(runtime=True, query="CREATE TABLE public.qa_forbidden_ddl(id integer)")
        if forbidden.returncode == 0 or "42501" not in forbidden.stderr:
            raise SmokeFailure("Runtime unexpectedly accepted DDL or failed for another reason")
        if value("SELECT to_regclass('public.qa_forbidden_ddl') IS NULL") != "t":
            raise SmokeFailure("Forbidden DDL left a table")
        checks.append("runtime DDL denied")

        duplicate = psql(runtime=True, query="INSERT INTO public.challenge_completions(user_id,challenge_id,awarded_points) SELECT user_id,challenge_id,100 FROM public.challenge_completions")
        if duplicate.returncode == 0 or "23505" not in duplicate.stderr:
            raise SmokeFailure("Unique completion constraint did not reject duplicate")
        invalid_fk = psql(runtime=True, query="INSERT INTO public.challenge_completions(user_id,challenge_id,awarded_points) SELECT 99999999,challenge_id,100 FROM public.challenge_completions LIMIT 1")
        if invalid_fk.returncode == 0 or "23503" not in invalid_fk.stderr:
            raise SmokeFailure("Foreign key did not reject missing user")
        checks.append("unique completion and foreign-key enforcement")

        before = fingerprint()
        repeated = psql(filename="01_schema.sql")
        if repeated.returncode == 0:
            raise SmokeFailure("Fresh installer accepted an existing schema")
        if fingerprint() != before or value("SELECT sum(awarded_points) FROM public.challenge_completions") != "100":
            raise SmokeFailure("Existing records changed after rejected schema rerun")
        checks.append("schema rerun rejected with every table unchanged and 100 QA points preserved")
    except (OSError, ValueError, subprocess.SubprocessError, SmokeFailure) as error:
        failure = str(error) if isinstance(error, SmokeFailure) else type(error).__name__
    finally:
        # Inspect this UUID name only. Remove its immutable ID only when its
        # ownership label AND exact name agree, even if docker run was interrupted.
        try:
            inspected = command([docker, "inspect", name], timeout=10)
            if inspected.returncode == 0:
                entries = json.loads(inspected.stdout)
                info = entries[0]
                identifier = info.get("Id", "")
                if info.get("Name") != "/" + name or info.get("Config", {}).get("Labels", {}).get(LABEL) != token or not re.fullmatch(r"[a-f0-9]{64}", identifier):
                    cleanup_ok = False
                else:
                    cleanup_ok = command([docker, "rm", "--force", identifier], timeout=20).returncode == 0
            elif created:
                # A container already removed by an operator also leaves no QA state.
                cleanup_ok = "No such" in inspected.stderr
        except (OSError, ValueError, IndexError, subprocess.SubprocessError):
            cleanup_ok = False

    summary = {"ok": failure is None and cleanup_ok, "checks": checks, "owned_container_removed": cleanup_ok}
    if failure:
        summary["failure"] = failure
    print(json.dumps(summary, ensure_ascii=False, indent=2))
    return 0 if summary["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
