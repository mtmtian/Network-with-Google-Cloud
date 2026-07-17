#!/usr/bin/env python3
import pathlib
import shlex
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
                output=\"$(run_deploy)\"
                printf '%s\\n' \"$output\"
                test -f \"$STATE_DIR/.secrets.env\"
                test ! -e \"$PROJECT_DIR/profiles/gcloud/.secrets.env\"
                test -f \"$PROJECT_DIR/clash-configs/frantech-mac.yaml\"
                test -f \"$PROJECT_DIR/clash-configs/frantech-iphone.yaml\"
                grep -F '配置文件  : {root}/clash-configs/frantech-*.yaml' <<<\"$output\" >/dev/null
                """
            )
            result = subprocess.run(
                ["bash", "-c", command],
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr + result.stdout)

    def test_server_env_quotes_special_values(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            state = root / "state"
            state.mkdir()
            command = textwrap.dedent(
                f"""
                set -euo pipefail
                PROJECT_DIR={shlex.quote(str(PROJECT_ROOT))}
                PROFILE_NAME=test
                NETWORK_NODE_STATE_DIR={shlex.quote(str(state))}
                . "$PROJECT_DIR/core/common.sh"
                . "$PROJECT_DIR/core/deploy.sh"
                DEVICES=mac
                setkv ANYTLS_PASS "a'b\\$c"
                target={shlex.quote(str(root / 'server-env.sh'))}
                build_server_env "$target"
                expected="a'b\\$c"
                . "$target"
                test "$ANYTLS_PASS" = "$expected"
                """
            )
            shutil.copy(PROJECT_ROOT / "core" / "common.sh", root / "common.sh")
            shutil.copy(PROJECT_ROOT / "core" / "deploy.sh", root / "deploy.sh")
            result = subprocess.run(
                ["bash", "-c", command],
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr + result.stdout)

    def test_cdn_setup_runs_with_active_profile_before_host_changes(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            shutil.copytree(PROJECT_ROOT / "core", root / "core")
            shutil.copytree(PROJECT_ROOT / "config", root / "config")
            fake_cf = root / "core" / "cloudflare.sh"
            fake_cf.write_text(
                "#!/usr/bin/env bash\n"
                "set -euo pipefail\n"
                "printf '%s' \"$PROFILE_NAME\" > \"$NETWORK_NODE_STATE_DIR/cf-profile\"\n"
                "printf 'CF_TUNNEL_TOKEN=test-tunnel\\n' >> \"$NETWORK_NODE_STATE_DIR/.secrets.env\"\n"
            )
            fake_cf.chmod(0o755)
            command = textwrap.dedent(
                f"""
                set -euo pipefail
                PROJECT_DIR={shlex.quote(str(root))}
                PROFILE_NAME=cdn-test
                NETWORK_NODE_STATE_DIR={shlex.quote(str(root / 'state'))}
                . "$PROJECT_DIR/core/common.sh"
                . "$PROJECT_DIR/core/deploy.sh"
                PROVIDER_TITLE='Test CDN'
                PROVIDER_DESCRIPTION='provider=test'
                provider_init() {{ :; }}
                provider_preflight() {{ :; }}
                provider_configure() {{
                    mkdir -p "$STATE_DIR"
                    cat > "$CONF_FILE" <<'EOF'
DEVICES="mac"
REALITY_TARGET=1.1.1.1:443
REALITY_SNI=
REALITY_PORT=443
CDN_ENABLE=true
CDN_ONLY=false
CDN_HOSTNAME=cdn.example.com
CDN_TUNNEL_NAME=cdn-test
EOF
                    printf 'CF_API_TOKEN=test-api-token\\n' > "$SECRETS_FILE"
                }}
                provider_provision() {{
                    test "$(cat \"$STATE_DIR/cf-profile\")" = "$PROFILE_NAME"
                    setkv STATIC_IP 203.0.113.10
                }}
                provider_install() {{ printf 'REALITY_PUBLIC_KEY=test-public-key\\n'; }}
                provider_print_summary() {{ :; }}
                run_deploy >/dev/null
                test -f "$STATE_DIR/cf-profile"
                test -f "$PROJECT_DIR/clash-configs/cdn-test-mac.yaml"
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
