from contextlib import redirect_stdout
import io
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch
from urllib.parse import unquote, urlsplit

sys.path.insert(0, str(Path(__file__).resolve().parents[1]/'tools'))
from private_env import read_private_env
from bootstrap_database import validate_cluster_identity
import write_application_env


class PrivateConfigurationTests(unittest.TestCase):
    def setUp(self):
        workspace = Path(__file__).resolve().parents[1]/'work'
        workspace.mkdir(exist_ok=True)
        self.temporary = tempfile.TemporaryDirectory(dir=workspace)
        if not Path(self.temporary.name).resolve().is_relative_to(workspace.resolve()):
            raise RuntimeError('La carpeta QA debe permanecer dentro del workspace.')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.config = self.root/'secrets.env'

    def config_file(self, content):
        self.config.write_text(content, encoding='utf-8')
        self.config.chmod(0o600)

    def test_literals_and_metacharacters_are_data_without_shell_expansion(self):
        self.config_file("PASSWORD='example*./2026'\nOTHER='$(touch should-not-exist)'\n")
        result = read_private_env(self.config, require_root=False)
        self.assertEqual(result['PASSWORD'], 'example*./2026')
        self.assertEqual(result['OTHER'], '$(touch should-not-exist)')
        self.assertFalse((self.root/'should-not-exist').exists())

    def test_rejects_duplicates_and_malformed_assignments(self):
        for value in ('A=one\nA=two\n', 'export A=one\n', 'A=one two\n'):
            with self.subTest(value=value):
                self.config_file(value)
                with self.assertRaises(ValueError):
                    read_private_env(self.config, require_root=False)

    def test_rejects_public_password_placeholders_without_echoing_their_values(self):
        for key in ('PG_ADMIN_PASSWORD', 'REDIS_ADMIN_PASSWORD', 'PG_APP_PASSWORD', 'REDIS_APP_PASSWORD'):
            for marker in ('REEMPLAZAR_EN_ARCHIVO_PRIVADO', 'GENERAR_EN_PRIVADO', 'CHANGE_ME'):
                with self.subTest(key=key, marker=marker):
                    self.config_file(f"{key}='{marker}'\n")
                    with self.assertRaisesRegex(ValueError, 'Contraseña de plantilla') as raised:
                        read_private_env(self.config, require_root=False)
                    self.assertNotIn(marker, str(raised.exception))

    def test_long_synthetic_password_with_special_characters_is_not_a_placeholder(self):
        value = 'qa-only_*./A2026_not_a_real_password'
        self.config_file(f"PG_ADMIN_PASSWORD='{value}'\n")
        self.assertEqual(read_private_env(self.config, require_root=False)['PG_ADMIN_PASSWORD'], value)

    def test_connection_urls_encode_passwords_and_do_not_replace_existing_files(self):
        pg = 'postgres*./example2026'
        redis = 'redis*./example2026'
        self.config_file(f"PG_APP_PASSWORD='{pg}'\nREDIS_APP_PASSWORD='{redis}'\n")
        target = self.root/'application.env'
        output = io.StringIO()
        argv = ['write_application_env.py', '--secrets-file', str(self.config),
                '--output', str(target), '--pg-ssl', 'verify-full']
        with patch.object(sys, 'argv', argv), patch.object(write_application_env, 'read_private_env',
                side_effect=lambda name: read_private_env(name, require_root=False)), redirect_stdout(output):
            write_application_env.main()
            original = target.read_bytes()
            with self.assertRaises(ValueError):
                write_application_env.main()
        self.assertEqual(target.read_bytes(), original)
        values = read_private_env(target, require_root=False)
        self.assertEqual(unquote(urlsplit(values['DATABASE_URL']).password), pg)
        self.assertEqual(unquote(urlsplit(values['REDIS_URL']).password), redis)
        self.assertEqual(urlsplit(values['DATABASE_URL']).query, 'ssl=verify-full')
        self.assertEqual(values['MANAGE_SCHEMA_ON_STARTUP'], 'false')
        self.assertNotIn(pg, output.getvalue())
        self.assertNotIn(redis, output.getvalue())
        if os.name != 'nt':
            self.assertEqual(target.stat().st_mode & 0o777, 0o600)


class PostgreSQLTargetTests(unittest.TestCase):
    def identity(self, **changes):
        return {'version': '160014', 'port': '5432',
                'data_directory': '/mnt/db_data/postgres',
                'config_file': '/etc/postgresql/16/main/postgresql.conf', **changes}

    def test_only_expected_native_cluster_is_accepted(self):
        validate_cluster_identity(self.identity())

    def test_other_version_port_cluster_or_directory_is_rejected(self):
        for change in ({'version': '170001'}, {'port': '5433'},
                       {'data_directory': '/var/lib/postgresql/16/main'},
                       {'config_file': '/etc/postgresql/16/other/postgresql.conf'}):
            with self.subTest(change=list(change)):
                with self.assertRaises(ValueError):
                    validate_cluster_identity(self.identity(**change))

    def test_malformed_identity_fails_without_reflecting_its_contents(self):
        sentinel = 'qa-only-never-reflect-this-content'
        for value in (None, [], {}, self.identity(version=sentinel), self.identity(port=sentinel)):
            with self.subTest(kind=type(value).__name__):
                with self.assertRaises(ValueError) as raised:
                    validate_cluster_identity(value)
                self.assertNotIn(sentinel, str(raised.exception))


if __name__ == '__main__':
    unittest.main()
