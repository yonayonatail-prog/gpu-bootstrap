#!/usr/bin/env python3
"""Declarative, resumable Linux GPU environment builder. No shell interpolation."""
from __future__ import annotations

import argparse
import concurrent.futures
import contextlib
from collections import deque
from dataclasses import dataclass
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import socket
import subprocess
import sys
import threading
import time
from urllib.parse import urlsplit
from urllib.request import urlopen

import yaml

GIB = 1024 ** 3
HERE = Path(__file__).resolve().parent


class Failure(RuntimeError):
    def __init__(self, stage, item, reason, action="Check the log and rerun the same bootstrap command."):
        self.stage, self.item, self.reason, self.action = stage, item, reason, action
        super().__init__(reason)


def redact(value):
    value = str(value)
    for name in ("HF_TOKEN", "CIVITAI_TOKEN", "GH_TOKEN", "GITHUB_TOKEN"):
        if os.environ.get(name):
            value = value.replace(os.environ[name], "[REDACTED]")
    value = re.sub(r"https?://[^\s<>'\"]+", "[remote URL]", value)
    return re.sub(r"(?i)(bearer\s+)[\w.~-]+", r"\1[REDACTED]", value)


def now():
    return datetime.now(timezone.utc).isoformat()


def digest(path):
    hasher = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(8 * 1024 * 1024), b""):
            hasher.update(chunk)
    return hasher.hexdigest()


def fingerprint(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True).encode()).hexdigest()


def atomic_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")
    tmp.replace(path)


def relative_path(value):
    if not isinstance(value, str) or not value or "\\" in value or ":" in value or value.startswith("-") or any(ord(c) < 32 for c in value):
        raise ValueError("Expected a safe relative POSIX path")
    path = PurePosixPath(value)
    if path.is_absolute() or any(part in ("..", ".") for part in value.split("/")):
        raise ValueError("Path traversal is not allowed")
    return path


def under(root, value):
    path = root / str(relative_path(value))
    if not path.resolve().is_relative_to(root.resolve()):
        raise ValueError("Path escapes its runtime directory")
    return path


def identifier(value):
    if not isinstance(value, str) or not re.fullmatch(r"[A-Za-z0-9_-]+", value):
        raise ValueError("Invalid identifier")
    return value


def https_url(value):
    if not isinstance(value, str) or any(ord(c) < 32 for c in value):
        raise ValueError("URL cannot contain control characters")
    parsed = urlsplit(value)
    if parsed.scheme != "https" or not parsed.netloc or parsed.username or parsed.password:
        raise ValueError("Use an HTTPS URL without embedded credentials")
    return value


def load_yaml(path):
    value = yaml.safe_load(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise ValueError(f"Expected a YAML mapping: {path.name}")
    return value


@dataclass
class Asset:
    model: str
    source: str
    spec: dict
    remote_path: str
    target: Path
    stage_path: Path
    size: int
    sha256: str

    def valid(self, path=None):
        path = self.target if path is None else path
        return path.is_file() and path.stat().st_size == self.size and digest(path) == self.sha256


def load_plan(repo, profile_name, runtime):
    identifier(profile_name)
    profile = load_yaml(repo / "profiles" / f"{profile_name}.yaml")
    if profile.get("name") != profile_name:
        raise ValueError("Profile name must match filename")
    if profile.get("services", {}).get("llm"):
        raise Failure("profile", profile_name, "LLM backend is not implemented in v0.1.", "Use video or image.")
    if profile.get("services") != {"comfyui": True, "llm": False}:
        raise ValueError("MVP profiles require services: {comfyui: true, llm: false}")
    registry = load_yaml(repo / "registry.yaml").get("models", {})
    nodes = load_yaml(repo / "comfy" / "custom_nodes.yaml").get("nodes", {})
    assets, selected_nodes, targets = [], {}, set()
    for model in profile.get("models", []):
        identifier(model)
        if model not in registry:
            raise ValueError(f"Unknown model ID: {model}")
        spec = registry[model]
        source = spec["source"]
        if source == "civitai":
            raise Failure("registry", model, "CivitAI backend is reserved, not implemented.", "Use a vetted direct URL with size_bytes and sha256.")
        if source not in ("huggingface", "url"):
            raise ValueError(f"Unsupported source for {model}")
        destination = str(relative_path(spec["destination"]))
        if source == "huggingface":
            if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", spec["repo"]):
                raise ValueError("Invalid Hugging Face repository ID")
            if not re.fullmatch(r"[0-9a-f]{40}", str(spec["revision"])):
                raise ValueError(f"{model}: revision must be a full commit SHA")
            files = spec["files"]
        else:
            https_url(spec["url"])
            files = [{"path": spec["filename"], "size_bytes": spec["size_bytes"], "sha256": spec["sha256"]}]
        if not files:
            raise ValueError(f"{model}: files must not be empty")
        for entry in files:
            remote = str(relative_path(entry["path"]))
            size = entry["size_bytes"]
            sha = str(entry["sha256"])
            if type(size) is not int or size <= 0 or not re.fullmatch(r"[0-9a-f]{64}", sha):
                raise ValueError(f"{model}: positive size_bytes and SHA-256 are required")
            target = under(runtime / "ComfyUI" / "models", f"{destination}/{PurePosixPath(remote).name}")
            if target in targets:
                raise ValueError(f"Duplicate model destination: {target.name}")
            targets.add(target)
            stage_path = under(runtime / "downloads", f"{model}/{fingerprint(spec)[:16]}/{remote}")
            assets.append(Asset(model, source, spec, remote, target, stage_path, size, sha))
    for node in profile.get("custom_nodes", []):
        identifier(node)
        if node not in nodes:
            raise ValueError(f"Unknown custom node ID: {node}")
        spec = nodes[node]
        https_url(spec["repo"])
        if not re.fullmatch(r"[0-9a-f]{40}", str(spec["revision"])):
            raise ValueError(f"{node}: pin a full commit SHA")
        selected_nodes[node] = spec
    for workflow in profile.get("workflows", []):
        path = under(repo / "comfy" / "workflows", workflow)
        json.loads(path.read_text(encoding="utf-8"))
    comfy = profile["comfyui"]
    https_url(comfy["repo"])
    if not re.fullmatch(r"[0-9a-f]{40}", str(comfy["revision"])):
        raise ValueError("Pin ComfyUI to a full commit SHA")
    if not 1024 <= int(comfy.get("port", 8188)) <= 65535:
        raise ValueError("Invalid ComfyUI port")
    for key, default in (("max_concurrent", 3), ("retries", 3)):
        if not 1 <= int(profile.get("download", {}).get(key, default)) <= 16:
            raise ValueError(f"Invalid download.{key}")
    for key in ("install_budget_gib", "reserve_gib"):
        if float(profile.get("disk", {}).get(key, 20 if key == "install_budget_gib" else 5)) < 0:
            raise ValueError("Disk budgets cannot be negative")
    return profile, assets, selected_nodes


def disk_preflight(runtime, assets, profile, installed=False):
    # Conservatively reserve the whole size of incomplete files; never assume sparse
    # files or an interrupted backend will reuse every byte already allocated.
    remaining = sum(asset.size for asset in assets if not asset.valid())
    disk = profile.get("disk", {})
    budget = 0 if installed else float(disk.get("install_budget_gib", 20)) * GIB
    required = remaining + budget + float(disk.get("reserve_gib", 5)) * GIB
    free = shutil.disk_usage(runtime).free
    if free < required:
        raise Failure("disk_preflight", "runtime", f"Need {required/GIB:.1f} GiB free; available {free/GIB:.1f} GiB.", "Use a larger Pod disk and rerun. No model download has started.")
    return required, free


def run_command(args, log, env=None, cwd=None):
    log.parent.mkdir(parents=True, exist_ok=True)
    tail = deque(maxlen=8)
    child_env = os.environ.copy()
    child_env.update(env or {})
    with log.open("a", encoding="utf-8") as output:
        process = subprocess.Popen([str(a) for a in args], stdout=subprocess.PIPE,
                                   stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL,
                                   text=True, errors="replace", env=child_env, cwd=cwd)
        try:
            for line in process.stdout:
                safe = redact(line)
                output.write(safe)
                output.flush()
                tail.append(safe.strip())
            result = process.wait()
        except BaseException:
            process.terminate()
            process.wait()
            raise
    if result:
        raise RuntimeError(f"{Path(str(args[0])).name} exited {result}: " + " | ".join(tail))


class HuggingFaceBackend:
    def download(self, asset, runtime, log):
        local = runtime / "downloads" / asset.model / fingerprint(asset.spec)[:16]
        hf = Path(sys.executable).parent / ("hf.exe" if os.name == "nt" else "hf")
        run_command([hf, "download", asset.spec["repo"], asset.remote_path,
                     "--revision", asset.spec["revision"], "--local-dir", local], log,
                    env={"HF_HUB_DISABLE_PROGRESS_BARS": "1", "HF_HOME": str(runtime / "hf-cache"),
                         "HF_XET_CHUNK_CACHE_SIZE_BYTES": "0", "HF_HUB_DOWNLOAD_TIMEOUT": "120"})


class DirectBackend:
    def download(self, asset, runtime, log):
        asset.stage_path.parent.mkdir(parents=True, exist_ok=True)
        # URL travels through stdin, never command-line arguments or aria2 output.
        args = ["aria2c", "--input-file=-", "--continue=true", "--auto-file-renaming=false",
                "--allow-overwrite=true", "--file-allocation=none", "--max-connection-per-server=2",
                "--split=2", "--max-tries=3", "--retry-wait=5", "--connect-timeout=30",
                "--timeout=120", "--console-log-level=error", "--summary-interval=0",
                "--check-integrity=true", f"--checksum=sha-256={asset.sha256}",
                f"--dir={asset.stage_path.parent}", f"--out={asset.stage_path.name}"]
        # No config file containing URL secrets is persisted.
        result = subprocess.run(args, input=asset.spec["url"] + "\n", text=True,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        with log.open("a", encoding="utf-8") as stream:
            stream.write(redact(result.stdout))
        if result.returncode:
            raise RuntimeError(f"aria2c exited {result.returncode}: {redact(result.stdout[-1500:])}")


BACKENDS = {"huggingface": HuggingFaceBackend, "url": DirectBackend}


class Builder:
    def __init__(self, repo, runtime, profile_name):
        self.repo, self.runtime, self.name = repo, runtime, profile_name
        self.profile, self.assets, self.nodes = load_plan(repo, profile_name, runtime)
        self.logs = runtime / "logs"
        self.logs.mkdir(parents=True, exist_ok=True)
        self.lock = threading.RLock()
        self.states = {asset.model: "QUEUED" for asset in self.assets}
        self.started = time.monotonic()
        self.node_count = 0
        self.environment = "QUEUED"
        self.samples = deque(maxlen=12)
        self.backends = {name: cls() for name, cls in BACKENDS.items()}
        self.venv = runtime / "comfy-venv"
        self.py = self.venv / "bin" / "python"
        self.comfy = runtime / "ComfyUI"
        self.service_file = runtime / "service.json"
        self.signature = fingerprint({"comfy": self.profile["comfyui"], "nodes": self.nodes,
                                      "installer": digest(repo / "scripts" / "install_comfy.sh"),
                                      "constraints": digest(repo / "scripts" / "torch-constraints.txt")})

    def status(self, stage, **extra):
        with self.lock:
            atomic_json(self.runtime / "status.json", {"profile": self.name, "stage": stage,
                        "updated_at": now(), "models": dict(self.states), **extra})

    def state(self, model, value):
        with self.lock:
            self.states[model] = value
            self.status("model_download")

    def download_model(self, model, assets):
        started_at, start = now(), time.monotonic()
        downloaded = 0
        status = "FAILED"
        try:
            all_cached = True
            for asset in assets:
                self.state(model, "VERIFYING")
                if asset.valid():
                    continue
                all_cached = False
                asset.stage_path.parent.mkdir(parents=True, exist_ok=True)
                last_error = None
                for attempt in range(int(self.profile.get("download", {}).get("retries", 3))):
                    try:
                        self.state(model, "DOWNLOADING")
                        # A fully downloaded staging file survives a crash before rename.
                        if not asset.valid(asset.stage_path):
                            self.backends[asset.source].download(asset, self.runtime, self.logs / f"{model}.log")
                        self.state(model, "VERIFYING")
                        if not asset.valid(asset.stage_path):
                            # Quarantine an invalid completed download; partial files remain
                            # managed by hf/aria2 so retry can resume them.
                            if asset.stage_path.exists():
                                asset.stage_path.replace(asset.stage_path.with_suffix(asset.stage_path.suffix + ".corrupt"))
                            raise RuntimeError("Downloaded file failed size/SHA-256 verification")
                        asset.target.parent.mkdir(parents=True, exist_ok=True)
                        asset.stage_path.replace(asset.target)
                        downloaded += asset.size
                        last_error = None
                        break
                    except Exception as exc:
                        last_error = exc
                        if attempt + 1 < int(self.profile.get("download", {}).get("retries", 3)):
                            time.sleep(min(2 ** attempt, 10))
                if last_error:
                    raise last_error
            status = "SKIPPED" if all_cached else "READY"
            self.state(model, status)
        except Exception as exc:
            self.state(model, "FAILED")
            raise Failure("model_download", model, redact(exc), "Check network, disk, and the model log. For gated HF models, set HF_TOKEN and accept the license; rerun.") from exc
        finally:
            elapsed = time.monotonic() - start
            record = {"model": model, "started_at": started_at, "completed_at": now(),
                      "bytes": sum(a.size for a in assets) if status != "FAILED" else downloaded,
                      "newly_completed_bytes": downloaded, "duration_seconds": elapsed,
                      "average_speed_bps": downloaded / max(elapsed, .001), "status": status}
            with self.lock, (self.logs / "downloads.jsonl").open("a", encoding="utf-8") as stream:
                stream.write(json.dumps(record) + "\n")

    def progress(self):
        # Count final files plus partial backend data, excluding cache metadata.
        done = 0
        parts = []
        with self.lock:
            states = dict(self.states)
        for model in states:
            assets = [a for a in self.assets if a.model == model]
            total = sum(a.size for a in assets)
            if states[model] in ("READY", "SKIPPED"):
                current = total
            else:
                current = 0
                for a in assets:
                    if a.target.is_file() and a.target.stat().st_size == a.size:
                        current += a.size
                    elif a.stage_path.is_file():
                        current += min(a.size, a.stage_path.stat().st_size)
                local = self.runtime / "downloads" / model
                for path in local.rglob("*.incomplete") if local.exists() else []:
                    try:
                        current += path.stat().st_size
                    except FileNotFoundError:
                        pass
                current = min(total, current)
            done += current
            parts.append(f"{model}: {states[model]} {current/GIB:.2f}/{total/GIB:.2f} GiB")
        self.samples.append((time.monotonic(), done))
        span = self.samples[-1][0] - self.samples[0][0]
        speed = max(0, done - self.samples[0][1]) / span if span > 0 else 0
        total = sum(a.size for a in self.assets)
        eta = f"{int((total-done)/speed)}s" if speed > 0 and done < total else "calculating..."
        print(f"ENVIRONMENT ComfyUI {self.environment}; Nodes {self.node_count}/{len(self.nodes)}", flush=True)
        print(" | ".join(parts), flush=True)
        print(f"TOTAL {done/GIB:.2f}/{total/GIB:.2f} GiB; observed {speed/1e6:.1f} MB/s; download ETA {eta}", flush=True)

    def downloads(self):
        grouped = {model: [a for a in self.assets if a.model == model] for model in self.states}
        self.progress()
        with concurrent.futures.ThreadPoolExecutor(max_workers=int(self.profile.get("download", {}).get("max_concurrent", 3))) as pool:
            pending = {pool.submit(self.download_model, model, assets) for model, assets in grouped.items()}
            errors = []
            while pending:
                completed, pending = concurrent.futures.wait(pending, timeout=5, return_when=concurrent.futures.FIRST_COMPLETED)
                for future in completed:
                    try:
                        future.result()
                    except Exception as exc:
                        errors.append(exc)
                self.progress()
            if errors:
                raise errors[0]

    def command(self, args, stage, item, cwd=None):
        try:
            run_command(args, self.logs / f"{stage}.log", cwd=cwd)
        except Exception as exc:
            raise Failure(stage, item, redact(exc)) from exc

    def git_revision(self, directory):
        if not (directory / ".git").exists():
            return None
        result = subprocess.run(["git", "-C", str(directory), "rev-parse", "HEAD"], capture_output=True, text=True)
        return result.stdout.strip() if result.returncode == 0 else None

    def sync_repo(self, directory, spec, item):
        directory.mkdir(parents=True, exist_ok=True)
        if not (directory / ".git").exists():
            self.command(["git", "init", directory], "git", item)
            self.command(["git", "-C", directory, "remote", "add", "origin", spec["repo"]], "git", item)
        origin = subprocess.run(["git", "-C", str(directory), "remote", "get-url", "origin"], capture_output=True, text=True)
        if origin.stdout.strip() != spec["repo"]:
            raise Failure("git", item, "Existing repository origin differs from configuration")
        dirty = subprocess.run(["git", "-C", str(directory), "status", "--porcelain", "--untracked-files=no"], capture_output=True, text=True)
        if dirty.returncode or dirty.stdout.strip():
            raise Failure("git", item, "Tracked files have local edits. Save or commit them before changing this environment.")
        if self.git_revision(directory) != spec["revision"]:
            self.command(["git", "-C", directory, "fetch", "--depth", "1", "origin", spec["revision"]], "git", item)
            self.command(["git", "-C", directory, "checkout", "--detach", spec["revision"]], "git", item)
        if self.git_revision(directory) != spec["revision"]:
            raise Failure("git", item, "Checked-out revision does not match the configured commit")

    def installed(self):
        stamp = self.runtime / "environment.json"
        return (stamp.exists() and self.py.exists() and
                json.loads(stamp.read_text()).get("signature") == self.signature and
                self.git_revision(self.comfy) == self.profile["comfyui"]["revision"] and
                all(self.git_revision(self.comfy / "custom_nodes" / node) == spec["revision"] for node, spec in self.nodes.items()))

    def install(self):
        self.status("environment")
        if self.installed():
            print("Environment already installed: SKIP", flush=True)
        else:
            self.sync_repo(self.comfy, self.profile["comfyui"], "ComfyUI")
            self.command(["bash", self.repo / "scripts" / "install_comfy.sh", self.comfy, self.venv], "dependencies", "ComfyUI")
            for node, spec in self.nodes.items():
                directory = under(self.comfy / "custom_nodes", node)
                self.sync_repo(directory, spec, node)
                requirements = directory / "requirements.txt"
                if requirements.exists():
                    self.command([self.py, "-m", "pip", "install", "-r", requirements,
                                  "-c", self.repo / "scripts" / "torch-constraints.txt"], "node_dependencies", node, cwd=directory)
                self.node_count += 1
                print(f"Custom Nodes {self.node_count}/{len(self.nodes)}", flush=True)
            self.command([self.py, "-m", "pip", "check"], "dependencies", "dependency consistency")
            atomic_json(self.runtime / "environment.json", {"signature": self.signature})
        self.node_count = len(self.nodes)
        self.environment = "READY"
        for name in self.profile.get("workflows", []):
            dest = under(self.comfy / "user" / "default" / "workflows", name)
            dest.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(under(self.repo / "comfy" / "workflows", name), dest)

    def live_service(self):
        if not self.service_file.exists():
            return None
        value = json.loads(self.service_file.read_text())
        try:
            proc = Path("/proc") / str(int(value["pid"]))
            args = (proc / "cmdline").read_bytes().split(b"\0")
            # /proc stat: field 22 = process start time; PID alone is insufficient.
            start = (proc / "stat").read_text().rsplit(")", 1)[1].split()[19]
            if str(self.comfy / "main.py").encode() in args and start == value["start_ticks"]:
                return value
        except (OSError, KeyError, ValueError):
            pass
        return None

    def check_existing_service(self):
        live = self.live_service()
        if live and live.get("signature") != self.signature:
            raise Failure("service", "ComfyUI", "A different environment is already running.", f"Stop the existing ComfyUI PID {live['pid']} before switching versions or nodes, then rerun.")
        port = int(self.profile["comfyui"].get("port", 8188))
        with socket.socket() as sock:
            if sock.connect_ex(("127.0.0.1", port)) == 0 and not live:
                raise Failure("service", "port", f"Port {port} is in use by another process.", "Stop that service or choose another comfyui.port.")

    def start_service(self):
        self.status("service_start")
        port = int(self.profile["comfyui"].get("port", 8188))
        process = None
        if not self.live_service():
            env = os.environ.copy()
            for key in ("GH_TOKEN", "GITHUB_TOKEN", "HF_TOKEN", "CIVITAI_TOKEN"):
                env.pop(key, None)
            with (self.logs / "comfyui.log").open("a") as output:
                process = subprocess.Popen([str(self.py), str(self.comfy / "main.py"), "--listen", "0.0.0.0", "--port", str(port)],
                                           cwd=self.comfy, env=env, stdin=subprocess.DEVNULL,
                                           stdout=output, stderr=subprocess.STDOUT, start_new_session=True)
            try:
                start_ticks = (Path("/proc") / str(process.pid) / "stat").read_text().rsplit(")", 1)[1].split()[19]
            except OSError as exc:
                raise Failure("service_start", "ComfyUI", "Process exited during launch. See comfyui.log") from exc
            atomic_json(self.service_file, {"pid": process.pid, "start_ticks": start_ticks, "signature": self.signature, "port": port})
        deadline = time.monotonic() + int(self.profile["comfyui"].get("startup_timeout_seconds", 300))
        while time.monotonic() < deadline:
            if process and process.poll() is not None:
                raise Failure("service_start", "ComfyUI", "Process exited. See logs/comfyui.log")
            try:
                with urlopen(f"http://127.0.0.1:{port}/system_stats", timeout=5) as response:
                    stats = json.load(response)
                if not self.live_service() or not any(d.get("type") == "cuda" for d in stats.get("devices", [])):
                    raise Failure("service_health", "ComfyUI", "Service does not report an active CUDA device")
                with urlopen(f"http://127.0.0.1:{port}/object_info", timeout=10) as response:
                    node_info = json.load(response)
                for filename in self.profile.get("workflows", []):
                    workflow = json.loads(under(self.repo / "comfy" / "workflows", filename).read_text())
                    required = {n["type"] for n in workflow.get("nodes", []) if n["type"] not in ("Note", "MarkdownNote", "Reroute")}
                    missing = required - set(node_info)
                    if missing:
                        raise Failure("service_health", filename, "Missing workflow nodes: " + ", ".join(sorted(missing)))
                self.status("READY", port=port)
                print(f"\n[READY]\nProfile: {self.name}\nGPU: {stats['devices'][0].get('name', 'CUDA')}\nComfyUI: http://0.0.0.0:{port}\nSetup time: {(time.monotonic()-self.started)/60:.1f} minutes\nModels: {len(self.states)}/{len(self.states)} READY\nNodes: {self.node_count}/{len(self.nodes)} READY", flush=True)
                return
            except Failure:
                raise
            except (OSError, ValueError):
                time.sleep(2)
        raise Failure("service_health", "ComfyUI", "Startup timed out. See logs/comfyui.log", "Check the GPU/driver and log, then rerun. A still-starting service will be reused.")

    def build(self):
        self.check_existing_service()
        self.status("disk_preflight")
        required, free = disk_preflight(self.runtime, self.assets, self.profile, self.installed())
        print(f"Disk preflight: need {required/GIB:.1f} GiB; free {free/GIB:.1f} GiB", flush=True)
        self.install()
        disk_preflight(self.runtime, self.assets, self.profile, installed=True)
        self.downloads()
        self.start_service()


@contextlib.contextmanager
def runtime_lock(runtime):
    import fcntl
    with (runtime / "orchestrator.lock").open("w") as handle:
        try:
            fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as exc:
            raise Failure("lock", "runtime", "Another orchestrator is running.", "Wait for the current run.") from exc
        yield


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("profile", nargs="?", default="video")
    parser.add_argument("--runtime-root", type=Path, default=Path(os.environ.get("RUNTIME_ROOT", "/workspace/runtime")))
    parser.add_argument("--repo-root", type=Path, default=HERE)
    parser.add_argument("--plan", action="store_true", help="Validate configuration without downloads, installation, or service start")
    args = parser.parse_args()
    try:
        runtime = args.runtime_root.resolve()
        if runtime == Path(runtime.anchor):
            raise ValueError("Runtime root cannot be a filesystem root")
        if args.plan:
            profile, assets, nodes = load_plan(args.repo_root, args.profile, runtime)
            print(json.dumps({"profile": profile["name"], "models": sorted({a.model for a in assets}),
                              "model_bytes": sum(a.size for a in assets), "nodes": list(nodes),
                              "targets": [str(a.target) for a in assets]}, indent=2))
            return 0
        if sys.platform != "linux":
            raise ValueError("Building requires Linux; use --plan on other platforms")
        runtime.mkdir(parents=True, exist_ok=True)
        with runtime_lock(runtime):
            builder = Builder(args.repo_root, runtime, args.profile)
            try:
                builder.build()
            except Exception as exc:
                builder.status("FAILED", reason=redact(exc))
                raise
        return 0
    except Exception as exc:
        failure = exc if isinstance(exc, Failure) else Failure("configuration", args.profile, redact(exc))
        print(f"\n[FAILED]\nStage: {failure.stage}\nItem: {failure.item}\nReason: {redact(failure.reason)}\nAction: {failure.action}", file=sys.stderr, flush=True)
        return 1


if __name__ == "__main__":
    sys.exit(main())
