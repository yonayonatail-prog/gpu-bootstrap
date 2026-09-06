import contextlib
import hashlib
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import threading
import functools
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
import unittest
from unittest.mock import patch

import yaml
import orchestrator as o


class OrchestratorTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.repo = self.root / "repo"
        self.repo.mkdir()
        for name in ("profiles", "comfy", "scripts"):
            shutil.copytree(o.HERE / name, self.repo / name)
        shutil.copy(o.HERE / "registry.yaml", self.repo / "registry.yaml")
        shutil.copy(o.HERE / "orchestrator.py", self.repo / "orchestrator.py")
        self.runtime = self.root / "runtime"
        self.runtime.mkdir()

    def fixture(self):
        content = b"verified model data"
        registry = {"models": {"small": {"source": "huggingface", "repo": "test/model",
                    "revision": "a" * 40, "destination": "checkpoints", "files": [
                    {"path": "nested/model.bin", "size_bytes": len(content), "sha256": hashlib.sha256(content).hexdigest()}]}}}
        (self.repo / "registry.yaml").write_text(yaml.safe_dump(registry))
        profile = o.load_yaml(self.repo / "profiles" / "image.yaml")
        profile["models"] = ["small"]
        profile["download"]["retries"] = 1
        (self.repo / "profiles" / "image.yaml").write_text(yaml.safe_dump(profile))
        return o.Builder(self.repo, self.runtime, "image"), content

    def test_bundled_profiles_and_registry(self):
        for name, count, expected_nodes in (("video", 3, {"ComfyUI-See-through"}), ("image", 1, set())):
            profile, assets, nodes = o.load_plan(self.repo, name, self.runtime)
            self.assertEqual(len(assets), count)
            self.assertGreater(sum(a.size for a in assets), 0)
            self.assertEqual(set(nodes), expected_nodes)
            self.assertEqual(profile["name"], name)

    def test_unknown_model_and_profile_traversal(self):
        path = self.repo / "profiles" / "image.yaml"
        value = o.load_yaml(path)
        value["models"] = ["missing"]
        path.write_text(yaml.safe_dump(value))
        with self.assertRaisesRegex(ValueError, "Unknown model"):
            o.load_plan(self.repo, "image", self.runtime)
        with self.assertRaises(ValueError):
            o.load_plan(self.repo, "../image", self.runtime)

    def test_llm_fails_explicitly(self):
        with self.assertRaisesRegex(o.Failure, "not implemented"):
            o.load_plan(self.repo, "llm", self.runtime)

    def test_insufficient_disk_before_install_or_download(self):
        builder, _ = self.fixture()
        with patch.object(builder, "check_existing_service"), patch.object(builder, "installed", return_value=False), \
             patch.object(o.shutil, "disk_usage", return_value=shutil._ntuple_diskusage(10, 9, 1)), \
             patch.object(builder, "install") as install, patch.object(builder, "downloads") as downloads:
            with self.assertRaises(o.Failure) as exc:
                builder.build()
            self.assertEqual(exc.exception.stage, "disk_preflight")
            install.assert_not_called()
            downloads.assert_not_called()

    def test_complete_file_skips_backend(self):
        builder, content = self.fixture()
        asset = builder.assets[0]
        asset.target.parent.mkdir(parents=True)
        asset.target.write_bytes(content)
        with patch.object(builder.backends["huggingface"], "download") as backend:
            builder.download_model("small", [asset])
            backend.assert_not_called()
        self.assertEqual(builder.states["small"], "SKIPPED")

    def test_failed_download_then_resume_on_rerun(self):
        builder, content = self.fixture()
        asset = builder.assets[0]
        def interrupted(*args):
            asset.stage_path.parent.mkdir(parents=True, exist_ok=True)
            asset.stage_path.write_bytes(content[:5])
            raise RuntimeError("HTTP 503")
        with patch.object(builder.backends["huggingface"], "download", side_effect=interrupted):
            with self.assertRaises(o.Failure):
                builder.download_model("small", [asset])
        self.assertEqual(builder.states["small"], "FAILED")
        self.assertFalse(asset.target.exists())
        builder2, _ = self.fixture()
        def resume(*args):
            self.assertEqual(asset.stage_path.read_bytes(), content[:5])
            with asset.stage_path.open("ab") as stream:
                stream.write(content[5:])
        with patch.object(builder2.backends["huggingface"], "download", side_effect=resume):
            builder2.download_model("small", [asset])
        self.assertEqual(asset.target.read_bytes(), content)
        records = [json.loads(line) for line in (builder.logs / "downloads.jsonl").read_text().splitlines()]
        self.assertEqual([r["status"] for r in records], ["FAILED", "READY"])

    def test_staging_complete_after_crash_does_not_download(self):
        builder, content = self.fixture()
        asset = builder.assets[0]
        asset.stage_path.parent.mkdir(parents=True)
        asset.stage_path.write_bytes(content)
        with patch.object(builder.backends["huggingface"], "download") as backend:
            builder.download_model("small", [asset])
            backend.assert_not_called()
        self.assertTrue(asset.valid())

    def test_same_size_corruption_is_not_ready(self):
        builder, content = self.fixture()
        asset = builder.assets[0]
        asset.target.parent.mkdir(parents=True)
        asset.target.write_bytes(b"x" * len(content))
        with patch.object(builder.backends["huggingface"], "download", side_effect=RuntimeError("network unavailable")):
            with self.assertRaises(o.Failure):
                builder.download_model("small", [asset])
        self.assertFalse(asset.valid())
        self.assertEqual(builder.states["small"], "FAILED")

    def test_failed_models_prevent_service_start(self):
        builder, _ = self.fixture()
        with patch.object(builder, "check_existing_service"), patch.object(builder, "installed", return_value=True), \
             patch.object(o, "disk_preflight", return_value=(0, 1)), patch.object(builder, "install"), \
             patch.object(builder, "downloads", side_effect=o.Failure("model_download", "small", "broken")), \
             patch.object(builder, "start_service") as start:
            with self.assertRaises(o.Failure):
                builder.build()
            start.assert_not_called()

    def test_secret_redaction(self):
        with patch.dict(os.environ, {"HF_TOKEN": "secret_value"}):
            result = o.redact("secret_value HTTP 403 https://host/model?token=other-secret Authorization: Bearer abcd")
            for secret in ("secret_value", "other-secret", "abcd"):
                self.assertNotIn(secret, result)

    def test_path_escape_and_duplicate_destinations(self):
        builder, _ = self.fixture()
        for path in ("../outside", "/tmp/a", "a/../../b", "C:\\secrets"):
            with self.assertRaises(ValueError):
                o.under(self.runtime, path)
        value = o.load_yaml(self.repo / "profiles" / "image.yaml")
        value["models"] *= 2
        (self.repo / "profiles" / "image.yaml").write_text(yaml.safe_dump(value))
        with self.assertRaisesRegex(ValueError, "Duplicate"):
            o.load_plan(self.repo, "image", self.runtime)

    def test_direct_backend_uses_stdin_and_resume(self):
        builder, _ = self.fixture()
        asset = builder.assets[0]
        asset.spec["url"] = "https://example.invalid/model?secret=hidden"
        result = subprocess.CompletedProcess([], 0, "done")
        with patch.object(o.subprocess, "run", return_value=result) as run:
            o.DirectBackend().download(asset, self.runtime, builder.logs / "direct.log")
        args = run.call_args.args[0]
        self.assertIn("--continue=true", args)
        self.assertFalse(any("hidden" in str(arg) for arg in args))
        self.assertIn("hidden", run.call_args.kwargs["input"])

    def test_hf_cli_uses_pinned_revision_and_staging(self):
        builder, _ = self.fixture()
        asset = builder.assets[0]
        with patch.object(o, "run_command") as run:
            o.HuggingFaceBackend().download(asset, self.runtime, builder.logs / "hf.log")
        args = run.call_args.args[0]
        self.assertIn("download", args)
        self.assertIn("a" * 40, args)
        self.assertIn("--local-dir", args)
        self.assertNotIn("--token", args)

    def test_workflow_link_integrity(self):
        for path in (self.repo / "comfy" / "workflows").glob("*.json"):
            workflow = json.loads(path.read_text())
            nodes = {n["id"]: n for n in workflow["nodes"]}
            for link_id, src, out_slot, dest, in_slot, typ in workflow["links"]:
                self.assertIn(link_id, nodes[src]["outputs"][out_slot]["links"])
                self.assertEqual(nodes[dest]["inputs"][in_slot]["link"], link_id)
                self.assertEqual(nodes[dest]["inputs"][in_slot]["type"], typ)

    @unittest.skipUnless(sys.platform == "linux", "POSIX flock integration")
    def test_concurrent_runtime_lock(self):
        with o.runtime_lock(self.runtime):
            with self.assertRaises(o.Failure):
                with o.runtime_lock(self.runtime):
                    pass

    def test_plan_cli_does_not_create_runtime(self):
        target = self.root / "not-created"
        result = subprocess.run([sys.executable, str(o.HERE / "orchestrator.py"), "video", "--plan", "--runtime-root", str(target)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(target.exists())

    @unittest.skipUnless(sys.platform == "linux", "Linux Bash launch command")
    def test_readme_one_liner_fetches_before_execute(self):
        command = (o.HERE / "README.md").read_text().split("```bash\n", 1)[1].split("\n```", 1)[0]
        fakebin = self.root / "bin"
        fakebin.mkdir()
        curl = fakebin / "curl"
        curl.write_text('#!/usr/bin/env python3\nimport sys\nfrom pathlib import Path\nassert "test-token" not in " ".join(sys.argv)\nassert "test-token" in sys.stdin.read()\nPath(sys.argv[sys.argv.index("-o")+1]).write_text(\'echo "PROFILE=$1"\\n\')\n')
        curl.chmod(0o700)
        env = dict(os.environ, GH_TOKEN="test-token", PATH=str(fakebin) + os.pathsep + os.environ["PATH"])
        result = subprocess.run(["bash", "-c", command], env=env, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("PROFILE=video", result.stdout)
        self.assertNotIn("test-token", result.stdout + result.stderr)
        curl.write_text('#!/bin/sh\nexit 22\n')
        result = subprocess.run(["bash", "-c", command], env=env, text=True, capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("PROFILE=", result.stdout)

    @unittest.skipUnless(shutil.which("aria2c"), "aria2c integration runs on CI")
    def test_real_aria2_download_and_verify(self):
        builder, content = self.fixture()
        asset = builder.assets[0]
        served = self.root / "served"
        served.mkdir()
        (served / "model.bin").write_bytes(content)
        handler = functools.partial(SimpleHTTPRequestHandler, directory=str(served))
        server = ThreadingHTTPServer(("127.0.0.1", 0), handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            # Local HTTP fixture exercises aria2; production config requires HTTPS.
            asset.source = "url"
            asset.spec["url"] = f"http://127.0.0.1:{server.server_port}/model.bin"
            builder.download_model("small", [asset])
            self.assertTrue(asset.valid())
        finally:
            server.shutdown()
            server.server_close()
            thread.join()

    @unittest.skipUnless(sys.platform == "linux", "Linux /proc service identity")
    def test_service_health_and_rerun_reuses_owned_process(self):
        import socket
        builder, _ = self.fixture()
        with socket.socket() as probe:
            probe.bind(("127.0.0.1", 0))
            port = probe.getsockname()[1]
        builder.profile["comfyui"]["port"] = port
        builder.profile["workflows"] = []
        builder.comfy.mkdir()
        builder.py.parent.mkdir(parents=True)
        builder.py.symlink_to(sys.executable)
        (builder.comfy / "main.py").write_text('''import json, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
class Handler(BaseHTTPRequestHandler):
 def do_GET(self):
  self.send_response(200); self.end_headers()
  self.wfile.write(json.dumps({"devices": [{"type": "cuda", "name": "test fixture"}]} if self.path == "/system_stats" else {}).encode())
HTTPServer(("127.0.0.1", int(sys.argv[sys.argv.index("--port")+1])), Handler).serve_forever()
''')
        try:
            builder.start_service()
            first = builder.live_service()
            self.assertIsNotNone(first)
            builder.check_existing_service()
            builder.start_service()
            self.assertEqual(builder.live_service()["pid"], first["pid"])
            builder.signature = "changed"
            with self.assertRaises(o.Failure):
                builder.check_existing_service()
        finally:
            live = builder.live_service()
            if live:
                import signal
                os.kill(live["pid"], signal.SIGTERM)
                os.waitpid(live["pid"], 0)


if __name__ == "__main__":
    unittest.main()
