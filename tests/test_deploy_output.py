#!/usr/bin/env python3
import pathlib
import shutil
import subprocess
import tempfile
import textwrap
import unittest


PROJECT_ROOT = pathlib.Path(__file__).resolve().parent.parent


class DeployOutputTest(unittest.TestCase):
    def test_vps_entrypoint_requires_explicit_profile(self):
        result = subprocess.run(
            ["bash", str(PROJECT_ROOT / "deploy-vps.sh")],
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("VPS_PROFILE", result.stderr)

    def test_reality_client_password_is_redacted_from_logs(self):
        command = (
            f'. "{PROJECT_ROOT / "core" / "common.sh"}"; '
            f'. "{PROJECT_ROOT / "core" / "deploy.sh"}"; '
            "printf 'before\\nREALITY_PUBLIC_KEY=client-secret\\nafter\\n' | redact_server_output"
        )
        result = subprocess.run(
            ["bash", "-c", command],
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            result.stdout,
            "before\nREALITY_PUBLIC_KEY=[redacted]\nafter\n",
        )
        self.assertNotIn("client-secret", result.stdout)

    def test_vps_profile_is_passed_to_secret_generation_subprocess(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            shutil.copytree(PROJECT_ROOT / "core", root / "core")
            shutil.copytree(PROJECT_ROOT / "config", root / "config")
            command = textwrap.dedent(
                f"""
                set -euo pipefail
                PROJECT_DIR='{root}'
                PROFILE_NAME=frantech
                NETWORK_NODE_STATE_DIR='{root / 'state'}'
                NETWORK_NODE_CLIENTS_DIR='{root / 'clients'}'
                . \"$PROJECT_DIR/core/common.sh\"
                . \"$PROJECT_DIR/core/deploy.sh\"
                PROVIDER_TITLE='Test VPS'
                PROVIDER_DESCRIPTION='provider=test'
                provider_init() {{ :; }}
                provider_preflight() {{ :; }}
                provider_configure() {{
                    mkdir -p \"$STATE_DIR\"
                    cp \"$PROJECT_DIR/config/deploy.conf.example\" \"$CONF_FILE\"
                }}
                provider_provision() {{ setkv STATIC_IP 203.0.113.10; }}
                provider_install() {{ printf 'REALITY_PUBLIC_KEY=test-public-key\\n'; }}
                provider_print_summary() {{ :; }}
                run_deploy
                test -f \"$STATE_DIR/.secrets.env\"
                test ! -e \"$PROJECT_DIR/profiles/gcloud/.secrets.env\"
                """
            )
            result = subprocess.run(
                ["bash", "-c", command],
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr + result.stdout)


if __name__ == "__main__":
    unittest.main()
