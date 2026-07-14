#!/usr/bin/env python3
import os
import pathlib
import subprocess
import tempfile
import unittest


PROJECT_ROOT = pathlib.Path(__file__).resolve().parent.parent


class MihomoConfigIntegrationTest(unittest.TestCase):
    def test_current_mihomo_accepts_generated_config(self):
        mihomo = os.environ.get("MIHOMO_BIN")
        if not mihomo or not pathlib.Path(mihomo).is_file():
            self.skipTest("MIHOMO_BIN is not available")

        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            (root / "deploy.conf").write_text(
                "REALITY_PORT=443\nREALITY_TARGET=1.1.1.1:443\nREALITY_SNI=\n"
                "DEVICES=mac\nCDN_ENABLE=false\n"
            )
            (root / ".secrets.env").write_text(
                "STATIC_IP=203.0.113.10\n"
                "REALITY_PUBLIC=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\n"
                "REALITY_SHORTID=0123456789abcdef\nHY2_PORT=31000\n"
                "ANYTLS_PORT=21000\nANYTLS_PASS=test-anytls-pass\n"
                "REALITY_UUID_mac=00000000-0000-4000-8000-000000000001\n"
                "HY2_PASS_mac=test-hy2-mac\n"
            )
            env = os.environ.copy()
            env["NETWORK_NODE_ROOT"] = str(root)
            env["NETWORK_NODE_STATE_DIR"] = str(root)
            env["NETWORK_NODE_PROFILE"] = "test"
            generated = subprocess.run(
                [os.environ.get("PYTHON", "python3"), str(PROJECT_ROOT / "core" / "gen-clash.py")],
                env=env,
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertEqual(generated.returncode, 0, generated.stderr)

            config = root / "clash-configs" / "test-mac.yaml"
            parsed = subprocess.run(
                [mihomo, "-t", "-d", tmp, "-f", str(config)],
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertEqual(parsed.returncode, 0, parsed.stdout + parsed.stderr)


if __name__ == "__main__":
    unittest.main()
