#!/usr/bin/env python3
import pathlib
import subprocess
import unittest


PROJECT_ROOT = pathlib.Path(__file__).resolve().parent.parent


class ProviderScriptTest(unittest.TestCase):
    def test_gcloud_retry_propagates_final_failure(self):
        script = (PROJECT_ROOT / "providers" / "gcp-provision.sh").read_text()
        retry_function = "\n".join(script.splitlines()[17:34])
        command = f"""
        set -euo pipefail
        PROJECT_DIR={str(PROJECT_ROOT)!r}
        . "$PROJECT_DIR/core/common.sh"
        {retry_function}
        GC=(false)
        sleep() {{ :; }}
        set +e
        gcloud_retry
        status=$?
        set -e
        test "$status" -eq 1
        """
        result = subprocess.run(
            ["bash", "-c", command],
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)


if __name__ == "__main__":
    unittest.main()
