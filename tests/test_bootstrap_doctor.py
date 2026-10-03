import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
BOOTSTRAP = ROOT / "bootstrap.sh"


class BootstrapDoctorTests(unittest.TestCase):
    def fake_nvidia_smi(self, directory, body):
        path = directory / "nvidia-smi"
        path.write_text("#!/bin/sh\n" + body, encoding="utf-8")
        path.chmod(0o700)

    def run_bootstrap(self, profile, smi_body):
        with tempfile.TemporaryDirectory() as tmp_name:
            tmp = Path(tmp_name)
            bin_dir = tmp / "bin"
            bin_dir.mkdir()
            self.fake_nvidia_smi(bin_dir, smi_body)
            runtime = tmp / "runtime"
            env = dict(os.environ)
            env["PATH"] = str(bin_dir) + os.pathsep + env["PATH"]
            env["RUNTIME_ROOT"] = str(runtime)
            result = subprocess.run(
                ["bash", str(BOOTSTRAP), profile],
                env=env,
                text=True,
                capture_output=True,
            )
            log_exists = (runtime / "logs" / "bootstrap.log").exists()
            return result, log_exists

    def test_doctor_reports_usable_gpu_without_installing(self):
        result, log_exists = self.run_bootstrap(
            "doctor",
            "case \"$*\" in\n"
            "  *--query-gpu=*) echo 'NVIDIA GeForce RTX 4090, 24564, 570.124.06' ;;\n"
            "  *) exit 0 ;;\n"
            "esac\n",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("[GPU PRECHECK PASS]", result.stdout)
        self.assertIn("NVIDIA GeForce RTX 4090", result.stdout)
        self.assertIn("[POD STATUS] USABLE", result.stdout)
        self.assertFalse(log_exists)

    def test_failed_gpu_stops_before_background_bootstrap(self):
        result, log_exists = self.run_bootstrap(
            "base",
            "echo 'NVIDIA-SMI has failed because it could not communicate with the NVIDIA driver.' >&2\n"
            "exit 9\n",
        )
        self.assertNotEqual(result.returncode, 0)
        combined = result.stdout + result.stderr
        self.assertIn("[GPU PRECHECK FAILED]", combined)
        self.assertIn("No models were downloaded.", combined)
        self.assertNotIn("[STARTED]", combined)
        self.assertFalse(log_exists)


if __name__ == "__main__":
    unittest.main()
