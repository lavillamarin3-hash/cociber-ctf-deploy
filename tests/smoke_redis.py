#!/usr/bin/env python3
"""Smoke test aislado de Redis 7; solo se ejecuta con --run.

No instala Redis en el host ni toca el laboratorio real. Docker crea un único
contenedor efímero sin red externa ni puertos publicados. Las contraseñas son
aleatorias, exclusivas de esta prueba y nunca se imprimen o pasan por argv.
La configuración procede del repositorio; bind/aclfile/dir se sustituyen en
una copia exclusiva de QA. No se ensaya llenar el límite de 8 GiB.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import queue
import secrets
import shutil
import subprocess
import sys
import threading
import time
import uuid


class SmokeFailure(RuntimeError):
    """Fallo de una condición de aceptación o del aislamiento de QA."""


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SmokeFailure(message)


class RedisSmoke:
    def __init__(self, root: Path) -> None:
        self.root = root.resolve(strict=True)
        self.token = uuid.uuid4().hex
        self.name = f"cociber-redis-smoke-{self.token}"
        self.work = self.root / "work"
        self.qa = self.work / f"redis-smoke-{self.token}"
        self.acl = self.qa / "users.acl"
        self.config = self.root / "configs" / "redis" / "redis.conf"
        self.qa_config = self.qa / "redis.conf"
        self.passwords = {"cociberctf": secrets.token_urlsafe(32), "cociber_app": secrets.token_urlsafe(32)}
        self.subscriber: subprocess.Popen[str] | None = None
        self._docker_started = False
        self._qa_created = False

    def redact(self, text: str) -> str:
        for password in self.passwords.values():
            text = text.replace(password, "[QA-SECRET]")
            text = text.replace(hashlib.sha256(password.encode("utf-8")).hexdigest(), "[QA-HASH]")
        return text.strip()[:1500]

    def docker(self, *args: str, timeout: float = 30, check: bool = True,
               user: str | None = None) -> subprocess.CompletedProcess[str]:
        env = os.environ.copy()
        env.pop("REDISCLI_AUTH", None)
        if user is not None:
            env["REDISCLI_AUTH"] = self.passwords[user]
        try:
            result = subprocess.run(["docker", *args], capture_output=True, text=True,
                                    encoding="utf-8", errors="replace", timeout=timeout, env=env)
        except FileNotFoundError as exc:
            raise SmokeFailure("No se encontró Docker CLI. No se modificó el laboratorio.") from exc
        except subprocess.TimeoutExpired as exc:
            raise SmokeFailure("Una operación de QA superó su plazo; se limpiará solo el contenedor propio.") from exc
        if check and result.returncode != 0:
            operation = args[0] if args else "desconocida"
            diagnostic = self.redact(result.stderr or result.stdout)
            raise SmokeFailure(f"Docker {operation} falló (código {result.returncode}): {diagnostic}")
        return result

    def cli_text(self, *command: str, user: str | None = "cociber_app", db: int = 0,
                 timeout: float = 15) -> str:
        args = ["exec"]
        if user is not None:
            # Docker recoge el valor del entorno del proceso cliente; argv
            # contiene únicamente el nombre de la variable, nunca el secreto.
            args.extend(["--env", "REDISCLI_AUTH"])
        args.extend([self.name, "redis-cli", "-2", "--json", "-h", "127.0.0.1", "-p", "6379"])
        if user is not None:
            args.extend(["--user", user])
        if db:
            args.extend(["-n", str(db)])
        args.extend(command)
        result = self.docker(*args, user=user, check=False, timeout=timeout)
        text = (result.stdout + "\n" + result.stderr).strip()
        if result.returncode != 0 and not any(marker in text for marker in ("NOAUTH", "NOPERM", "WRONGPASS")):
            raise SmokeFailure(f"redis-cli no pudo ejecutar una comprobación de QA: {self.redact(text)}")
        return text

    def cli(self, *command: str, user: str = "cociber_app", db: int = 0):
        text = self.cli_text(*command, user=user, db=db)
        require(not any(marker in text for marker in ("NOAUTH", "NOPERM", "WRONGPASS")),
                f"Se rechazó una operación permitida: {self.redact(text)}")
        try:
            return json.loads(text)
        except json.JSONDecodeError as exc:
            raise SmokeFailure(f"redis-cli no produjo JSON válido: {self.redact(text)}") from exc

    def denied(self, *command: str, user: str | None = "cociber_app", marker: str = "NOPERM") -> None:
        # redis-cli puede devolver exit code 0 ante errores del servidor.
        require(marker in self.cli_text(*command, user=user),
                f"No se rechazó la operación {command[0]} como se esperaba ({marker}).")

    def prepare(self) -> None:
        require(self.config.is_file(), "No existe configs/redis/redis.conf en el repositorio esperado.")
        require(not self.work.is_symlink(), "work no puede ser un enlace simbólico.")
        self.work.mkdir(mode=0o700, exist_ok=True)
        require(self.work.resolve() == self.work, "work debe resolver al directorio absoluto previsto.")
        require(self.qa.resolve(strict=False) == self.qa and self.qa.is_relative_to(self.root),
                "El directorio de QA sale del workspace esperado.")
        self.qa.mkdir(mode=0o700, exist_ok=False)
        self._qa_created = True
        digest = lambda user: hashlib.sha256(self.passwords[user].encode("utf-8")).hexdigest()
        self.acl.write_text(
            "user default off resetpass resetchannels -@all\n"
            f"user cociberctf on #{digest('cociberctf')} ~* &* +@all\n"
            f"user cociber_app on #{digest('cociber_app')} ~* &ctf:* "
            "+@read +@write +@connection +@pubsub +@scripting -@admin -@dangerous\n",
            encoding="utf-8", newline="\n",
        )
        # Solo hashes de contraseñas sintéticas de QA. El usuario redis del
        # contenedor debe poder leer el archivo bind-mounted, que es read-only.
        self.acl.chmod(0o644)
        # Redis valida y cambia dir mientras parsea el archivo; un --dir al
        # final del argv NO evita el fallo si la ruta original no existe.
        replacements = {"bind": "bind 127.0.0.1", "aclfile": "aclfile /usr/local/etc/redis/users.acl", "dir": "dir /data"}
        seen = {key: 0 for key in replacements}
        rendered = []
        for line in self.config.read_text(encoding="utf-8").splitlines():
            stripped = line.strip()
            key = stripped.split(None, 1)[0] if stripped and not stripped.startswith("#") else ""
            if key in replacements:
                seen[key] += 1
                line = replacements[key]
            rendered.append(line)
        require(all(count == 1 for count in seen.values()), "Se esperaba una única directiva bind/aclfile/dir en la plantilla pública.")
        self.qa_config.write_text("\n".join(rendered) + "\n", encoding="utf-8", newline="\n")
        self.qa_config.chmod(0o644)

    def start(self) -> None:
        self._docker_started = True
        self.docker(
            "run", "--detach", "--name", self.name,
            "--label", f"cociber.ctf.qa.id={self.token}",
            "--label", "cociber.ctf.qa.kind=redis-smoke",
            "--network", "none", "--memory", "512m", "--memory-swap", "512m",
            "--tmpfs", "/data:rw,noexec,nosuid,size=128m",
            "--mount", f"type=bind,source={self.qa_config},target=/usr/local/etc/redis/qa.conf,readonly",
            "--mount", f"type=bind,source={self.acl},target=/usr/local/etc/redis/users.acl,readonly",
            "redis:7-alpine", "redis-server", "/usr/local/etc/redis/qa.conf", timeout=180,
        )
        deadline = time.monotonic() + 35
        last_error = ""
        while time.monotonic() < deadline:
            try:
                if self.cli("PING", user="cociberctf") == "PONG":
                    return
            except SmokeFailure as exc:
                last_error = str(exc)
                state = self.docker("inspect", self.name, check=False)
                if state.returncode == 0:
                    details = json.loads(state.stdout)
                    if details and details[0].get("State", {}).get("Status") in {"exited", "dead"}:
                        break
            time.sleep(0.5)
        logs = self.docker("logs", "--tail", "35", self.name, check=False)
        diagnostic = self.redact(logs.stdout + "\n" + logs.stderr)
        raise SmokeFailure(f"El Redis aislado no respondió PONG: {last_error}. Inicio del servidor: {diagnostic}")

    def test_admin_and_config(self) -> None:
        require(self.cli("PING", user="cociberctf") == "PONG", "Falló PONG administrativo.")
        require(self.cli("ACL", "WHOAMI", user="cociberctf") == "cociberctf", "Identidad administrativa incorrecta.")
        # redis-cli presenta INFO como texto incluso con --json.
        info = self.cli_text("INFO", "server", user="cociberctf")
        require(isinstance(info, str), "INFO server devolvió un formato inesperado.")
        fields = dict(line.split(":", 1) for line in info.splitlines() if ":" in line and not line.startswith("#"))
        require(fields.get("redis_version", "").startswith("7."), "La imagen no ejecuta Redis major 7.")
        config = self.cli("CONFIG", "GET", "maxmemory", "maxmemory-policy", "dir", "appendonly", user="cociberctf")
        require(isinstance(config, list) and len(config) % 2 == 0, "CONFIG GET no produjo una lista RESP2 válida.")
        values = dict(zip(config[::2], config[1::2]))
        require(values.get("maxmemory") == "8589934592", "maxmemory no conserva 8 GiB.")
        require(values.get("maxmemory-policy") == "noeviction", "La política no es noeviction.")
        require(values.get("dir") == "/data" and values.get("appendonly") == "yes", "Persistencia no corresponde al directorio efímero de QA.")
        self.denied("PING", user=None, marker="NOAUTH")
        print("PASS Redis 7: administrador, PONG, NOAUTH y configuración 8 GiB/noeviction")

    def test_application(self) -> None:
        key = f"ctf:qa:{self.token}:value"
        require(self.cli("PING") == "PONG", "Falló PONG de aplicación.")
        require(self.cli("SELECT", "1") == "OK", "La aplicación no puede seleccionar su base de datos.")
        require(self.cli("SET", key, "qa-db0", "EX", "60") == "OK", "Falló SET con TTL en db0.")
        require(self.cli("SET", key, "qa-db1", "EX", "60", db=1) == "OK", "Falló SET con TTL en db1.")
        require(self.cli("GET", key) == "qa-db0", "GET no recupera el valor de db0.")
        require(self.cli("GET", key, db=1) == "qa-db1", "SELECT/GET no aísla db1 de db0.")
        lua = "redis.call('SET', KEYS[1], ARGV[1], 'EX', 60); return redis.call('GET', KEYS[1])"
        require(self.cli("EVAL", lua, "1", f"ctf:qa:{self.token}:lua", "qa-lua") == "qa-lua",
                "EVAL no puede operar la clave permitida mediante Lua.")
        for command in (("CONFIG", "GET", "maxmemory"), ("ACL", "LIST"), ("FLUSHALL",)):
            self.denied(*command)
        self.denied("PUBLISH", f"foreign:{self.token}", "qa-denied")
        self.denied("SUBSCRIBE", f"foreign:{self.token}")
        print("PASS aplicación: SET/GET, SELECT, Lua/EVAL y rechazo de administración/canal ajeno")

    def test_pubsub(self) -> None:
        channel = f"ctf:qa:{self.token}:updates"
        env = os.environ.copy()
        env["REDISCLI_AUTH"] = self.passwords["cociber_app"]
        self.subscriber = subprocess.Popen(
            ["docker", "exec", "--env", "REDISCLI_AUTH", self.name,
             "redis-cli", "-2", "--raw", "--user", "cociber_app", "-h", "127.0.0.1",
             "SUBSCRIBE", channel], stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True, encoding="utf-8", errors="replace", env=env,
        )
        lines: queue.Queue[str | None] = queue.Queue()

        def read_lines() -> None:
            assert self.subscriber is not None and self.subscriber.stdout is not None
            for line in self.subscriber.stdout:
                lines.put(line.rstrip("\r\n"))
            lines.put(None)

        reader = threading.Thread(target=read_lines, daemon=True)
        reader.start()

        def next_line() -> str:
            try:
                value = lines.get(timeout=12)
            except queue.Empty as exc:
                raise SmokeFailure("El suscriptor de QA no recibió respuesta antes del plazo.") from exc
            require(value is not None, "El suscriptor de QA terminó inesperadamente.")
            return value

        require([next_line(), next_line(), next_line()] == ["subscribe", channel, "1"], "SUBSCRIBE no confirmó el canal ctf autorizado.")
        require(self.cli("PUBLISH", channel, "qa-message") == 1, "PUBLISH no encontró al suscriptor real de QA.")
        require([next_line(), next_line(), next_line()] == ["message", channel, "qa-message"], "El suscriptor no recibió el contenido publicado.")
        print("PASS Pub/Sub real: canal ctf autorizado, suscripción y entrega de mensaje")

    def cleanup(self) -> list[str]:
        errors: list[str] = []
        if self.subscriber is not None and self.subscriber.poll() is None:
            try:
                self.subscriber.terminate()
                try:
                    self.subscriber.wait(timeout=8)
                except subprocess.TimeoutExpired:
                    self.subscriber.kill()
                    self.subscriber.wait(timeout=8)
            except (OSError, subprocess.TimeoutExpired):
                errors.append("No se pudo finalizar el cliente suscriptor propio; se retirará el contenedor de QA.")
        if self._docker_started:
            try:
                listing = self.docker("container", "ls", "--all", "--filter", f"name=^/{self.name}$", "--format", "{{.Names}}")
                if listing.stdout.strip():
                    require(listing.stdout.strip() == self.name, "El nombre encontrado no corresponde al contenedor propio.")
                    inspected = self.docker("inspect", self.name)
                    details = json.loads(inspected.stdout)
                    require(isinstance(details, list) and len(details) == 1 and details[0].get("Name") == f"/{self.name}",
                            "La inspección no corresponde al único contenedor propio.")
                    labels = details[0].get("Config", {}).get("Labels", {})
                    require(isinstance(labels, dict) and labels.get("cociber.ctf.qa.id") == self.token and labels.get("cociber.ctf.qa.kind") == "redis-smoke",
                            "Las etiquetas del contenedor no corresponden a esta prueba; no se eliminará.")
                    self.docker("rm", "--force", self.name)
            except (SmokeFailure, json.JSONDecodeError) as exc:
                errors.append(str(exc))
        if self._qa_created:
            # Windows: validar la ruta absoluta final antes de borrar de forma
            # recursiva. Solo se elimina el subdirectorio UUID creado aquí.
            expected = self.root / "work" / f"redis-smoke-{self.token}"
            resolved = self.qa.resolve(strict=False)
            if (self.qa == expected and resolved == expected and resolved.is_relative_to(self.root)
                    and not self.qa.is_symlink() and self.qa.parent.resolve() == self.work):
                try:
                    shutil.rmtree(resolved)
                except OSError:
                    errors.append("No se pudo retirar el directorio sintético de QA; revisa work/redis-smoke-UUID.")
            else:
                errors.append("Cambió la ruta del directorio de QA; se conservó para evitar borrar otro destino.")
        self.passwords.clear()
        return errors


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run", action="store_true", help="Autoriza crear y retirar exclusivamente el contenedor efímero de QA.")
    args = parser.parse_args()
    if not args.run:
        parser.error("Falta --run. No se creó ningún contenedor ni archivo de QA.")
    smoke = RedisSmoke(Path(__file__).resolve().parent.parent)
    failure: str | None = None
    try:
        smoke.prepare()
        smoke.start()
        smoke.test_admin_and_config()
        smoke.test_application()
        smoke.test_pubsub()
    except (SmokeFailure, OSError) as exc:
        failure = str(exc)
    finally:
        cleanup_errors = smoke.cleanup()
    if failure:
        print(f"FAIL {failure}", file=sys.stderr)
    for error in cleanup_errors:
        print(f"FAIL limpieza: {error}", file=sys.stderr)
    if failure or cleanup_errors:
        return 1
    print("PASS limpieza: solo el contenedor y los archivos sintéticos de esta prueba fueron retirados")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
