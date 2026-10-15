"""Exercise release scripts locally; every service/network command is a stub."""

import fcntl
import hashlib
import io
import json
import os
from pathlib import Path
import re
import select
import shutil
import signal
import stat
import subprocess
import tarfile
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
PACKAGE = ROOT / "deploy/package_release.sh"
PROMOTE = ROOT / "deploy/promote_release.sh"
SHA_A = "a" * 40
SHA_B = "b" * 40
COOKIE = "synthetic-private-cookie"
ENV_SECRET = "synthetic-server-only-password"

RELEASE_BIN = r'''#!/usr/bin/env python3
import json, os, stat, sys
from pathlib import Path
root = Path(__file__).resolve().parents[1]
label = (root / "lib/app/LABEL").read_text().strip()
phase = "seed" if "seed_demo" in " ".join(sys.argv) else "migrate"
cookie = root / "releases/COOKIE"
try:
    os.fstat(9)
    lock_fd_open = True
except OSError:
    lock_fd_open = False
event = {"phase": phase, "label": label, "path": str(root),
         "lock_fd_open": lock_fd_open,
         "cookie_present": cookie.exists(),
         "cookie_ok": cookie.exists() and cookie.read_text() == os.environ["EXPECTED_COOKIE"],
         "cookie_override_ok": os.environ.get("RELEASE_COOKIE") == "synthetic-env-cookie",
         "cookie_mode": stat.S_IMODE(cookie.stat().st_mode) if cookie.exists() else None,
         "parent_mode": stat.S_IMODE(root.parent.stat().st_mode)}
with open(os.environ["EVENT_LOG"], "a") as log:
    log.write(json.dumps(event) + "\n")
if phase == "migrate" and os.environ.get("GATE_LABEL") == label:
    with open(os.environ["GATE_READY"], "w") as ready:
        ready.write("ready\n")
    with open(os.environ["GATE_RELEASE"]) as release:
        release.readline()
sys.exit(1 if os.environ.get("FAIL_MIGRATE_LABEL") == label else 0)
'''

COMMAND_STUB = r'''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
name = Path(sys.argv[0]).name
if name == "sudo":
    os.execvp(sys.argv[1], sys.argv[1:])
if name == "flock":
    if os.environ.get("FLOCK_NOTIFY"):
        with open(os.environ["FLOCK_NOTIFY"], "w") as notify:
            notify.write("locking\n")
    os.execv(os.environ["REAL_FLOCK"], ["flock"] + sys.argv[1:])
root = Path(os.environ["INSTALL_DIR"])
if name == "mv":
    paths = [Path(arg) for arg in sys.argv[1:] if not arg.startswith("-")]
    failed_source = os.environ.get("FAIL_MOVE_SOURCE", "")
    source_matches = paths and ((failed_source == "current" and paths[-2] == root)
        or (failed_source == "candidate" and paths[-2].name == "candidate"))
    marker = Path(os.environ["MOVE_FAILURE_MARKER"])
    if source_matches and not marker.exists():
        marker.touch()
        sys.exit(1)
    os.execv(os.environ["REAL_MV"], ["mv"] + sys.argv[1:])
label_file = root / "lib/app/LABEL"
label = label_file.read_text().strip() if label_file.exists() else "missing"
phase = "health" if name == "curl" else "restart" if "restart" in sys.argv else name
with open(os.environ["EVENT_LOG"], "a") as log:
    log.write(json.dumps({"phase": phase, "label": label}) + "\n")
if phase == "health" and os.environ.get("GATE_HEALTH_LABEL") == label:
    with open(os.environ["HEALTH_READY"], "w") as ready:
        ready.write("ready\n")
    with open(os.environ["HEALTH_RELEASE"]) as release:
        release.readline()
failed = os.environ.get("FAIL_HEALTH_LABEL" if phase == "health" else "FAIL_RESTART_LABEL")
sys.exit(1 if failed == label else 0)
'''


class ReleaseArtifactsTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.work = Path(self.temporary.name)
        self.stubs = self.work / "stubs"
        self.stubs.mkdir()
        for command in ("sudo", "systemctl", "curl", "journalctl", "flock", "mv"):
            self.executable(self.stubs / command, COMMAND_STUB)
        # Retry loops remain deterministic and fast; no real service/network is used.
        self.executable(self.stubs / "sleep", "#!/bin/sh\nexit 0\n")
        self.events = self.work / "events.jsonl"
        self.env = os.environ.copy()
        self.env.update(
            PATH=str(self.stubs) + os.pathsep + os.environ["PATH"],
            EVENT_LOG=str(self.events),
            REAL_FLOCK=shutil.which("flock") or "/usr/bin/flock",
            REAL_MV=shutil.which("mv") or "/usr/bin/mv",
            MOVE_FAILURE_MARKER=str(self.work / "move-failed-once"),
            EXPECTED_COOKIE=COOKIE,
        )
        self.current = self.work / "production"
        self.make_installed(self.current)

    def executable(self, path, text):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
        path.chmod(0o755)

    def make_release(self, path, label):
        self.executable(path / "bin/residency_schedule", RELEASE_BIN)
        (path / "lib/app").mkdir(parents=True)
        (path / "lib/app/LABEL").write_text(label)
        (path / "releases").mkdir()
        (path / "releases/start_erl.data").write_text("synthetic runtime version\n")
        (path / "releases/0.1.0").mkdir()
        (path / "releases/0.1.0/sys.config").write_text("[].\n")
        (path / "releases/COOKIE").write_text(COOKIE)
        (path / "releases/COOKIE").chmod(0o600)
        return path

    def make_installed(self, path, label="legacy"):
        self.make_release(path, label)
        (path / ".env").write_text(
            "DATABASE_URL=" + ENV_SECRET + "\nRELEASE_COOKIE=synthetic-env-cookie\n"
        )
        (path / ".env").chmod(0o600)
        for name in (".env.backup", "erl_crash.dump", "config.backup"):
            (path / name).write_text("synthetic-runtime-private-data")
        (path / "tmp").mkdir()
        (path / "tmp/private").write_text("synthetic-runtime-private-data")
        (path / "tmp/runtime.sys.config").write_text("synthetic-runtime-private-data")

    def run_script(self, script, *args, env=None):
        self.assertTrue(script.is_file(), f"missing required release script: {script.name}")
        return subprocess.run(
            ["bash", str(script), *map(str, args)],
            env=env or self.env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=20,
        )

    def package(self, sha=SHA_A, label="A"):
        release = self.make_release(self.work / ("release-" + sha + "-" + label), label)
        output = self.work / ("artifact-" + sha + "-" + label)
        result = self.run_script(PACKAGE, release, output, sha)
        self.assertEqual(result.returncode, 0, result.stderr)
        archive = output / f"release-{sha}.tar.gz"
        manifest = output / f"release-{sha}.sha256"
        self.assertTrue(archive.is_file())
        self.assertTrue(manifest.is_file())
        self.verify_checksum(archive, manifest)
        self.assert_archive_private(archive)
        with tarfile.open(archive) as tar:
            identity = next(m for m in tar.getmembers() if m.name.removeprefix("./") == "RELEASE_ID")
            self.assertEqual(tar.extractfile(identity).read(), (sha + "\n").encode())
        return output

    def artifact_identity(self, artifact, sha=SHA_A):
        digest = hashlib.sha256((artifact / f"release-{sha}.tar.gz").read_bytes()).hexdigest()
        return sha + "-" + digest

    def promotion_env(self, artifact, sha=SHA_A, install=None, **overrides):
        env = self.env.copy()
        env.update(
            INSTALL_DIR=str(install or self.current),
            SERVICE="synthetic-residency-service",
            APP_PORT="4999",
            SEED_DEMO="false",
            RELEASE_ID=sha,
            DEPLOY_RUN_ID="run-" + sha[:8],
            ARTIFACT_DIR=str(artifact),
        )
        env.update(overrides)
        return env

    def promote(self, artifact, sha=SHA_A, install=None, **overrides):
        return self.run_script(
            PROMOTE,
            env=self.promotion_env(artifact, sha, install, **overrides),
        )

    def logged(self):
        return [json.loads(line) for line in self.events.read_text().splitlines()] if self.events.exists() else []

    def installed_label(self, install=None):
        return ((install or self.current) / "lib/app/LABEL").read_text()

    def verify_checksum(self, archive, manifest):
        fields = manifest.read_text().strip().split()
        self.assertEqual(fields, [hashlib.sha256(archive.read_bytes()).hexdigest(), archive.name])
        checked = subprocess.run(
            ["sha256sum", "--check", manifest.name], cwd=archive.parent, capture_output=True
        )
        self.assertEqual(checked.returncode, 0)

    def assert_archive_private(self, archive):
        with tarfile.open(archive) as tar:
            self.assertIn("releases/0.1.0/sys.config", [m.name.removeprefix("./") for m in tar.getmembers()])
            for member in tar.getmembers():
                name = member.name.removeprefix("./")
                self.assertFalse(any(part.startswith(".env") for part in Path(name).parts), name)
                self.assertNotEqual(name, "releases/COOKIE")
                self.assertNotIn(name, ("erl_crash.dump", "config.backup", "tmp/private", "tmp/runtime.sys.config"))
                self.assertFalse(member.issym() or member.islnk(), name)
                if member.isfile():
                    payload = tar.extractfile(member).read()
                    self.assertNotIn(COOKIE.encode(), payload)
                    self.assertNotIn(ENV_SECRET.encode(), payload)
                    self.assertNotIn(b"synthetic-runtime-private-data", payload)

    def assert_private_current(self, install=None):
        path = install or self.current
        self.assertIn(ENV_SECRET, (path / ".env").read_text())
        self.assertIn("RELEASE_COOKIE=synthetic-env-cookie", (path / ".env").read_text())
        self.assertEqual(stat.S_IMODE((path / ".env").stat().st_mode), 0o600)
        self.assertEqual((path / "releases/COOKIE").read_text(), COOKIE)
        self.assertEqual(stat.S_IMODE((path / "releases/COOKIE").stat().st_mode), 0o600)

    def assert_no_private_retention(self, install=None):
        path = install or self.current
        for candidate in path.parent.glob(path.name + ".deploy/**/*"):
            self.assertNotIn(candidate.name, (".env", "COOKIE"), str(candidate))
        for archive in path.parent.glob(path.name + ".artifacts/*.tar.gz"):
            self.assert_archive_private(archive)

    def test_one_secret_free_artifact_promotes_unchanged_to_production_and_demo(self):
        artifact = self.package()
        archive = artifact / f"release-{SHA_A}.tar.gz"
        original_bytes = archive.read_bytes()
        identity = self.artifact_identity(artifact)
        demo = self.work / "demo"
        self.make_installed(demo)
        production = self.promote(artifact)
        demonstration = self.promote(artifact, install=demo, SEED_DEMO="true")
        self.assertEqual(production.returncode, 0, production.stderr)
        self.assertEqual(demonstration.returncode, 0, demonstration.stderr)
        self.assertEqual(archive.read_bytes(), original_bytes)
        for install in (self.current, demo):
            self.assertEqual(self.installed_label(install), "A")
            self.assertEqual((install / "RELEASE_ID").read_text().strip(), SHA_A)
            self.assertEqual((install / "ARTIFACT_ID").read_text().strip(), identity)
            self.assertEqual(Path(str(install) + ".artifacts", identity + ".tar.gz").read_bytes(), original_bytes)
            self.assert_private_current(install)
            self.assert_no_private_retention(install)
        events = self.logged()
        self.assertEqual([e["phase"] for e in events], ["migrate", "restart", "health", "migrate", "seed", "restart", "health"])
        for event in events:
            if event["phase"] in ("migrate", "seed"):
                self.assertTrue(event["cookie_ok"])
                self.assertTrue(event["cookie_override_ok"])
                self.assertEqual(event["cookie_mode"], 0o600)
                self.assertEqual(event["parent_mode"], 0o700)
        for result in (production, demonstration):
            self.assertNotIn(COOKIE, result.stdout + result.stderr)
            self.assertNotIn(ENV_SECRET, result.stdout + result.stderr)

    def test_later_success_retains_verified_previous_archive_and_secret_free_legacy_snapshot(self):
        artifact_a = self.package()
        artifact_b = self.package(SHA_B, "B")
        self.assertEqual(self.promote(artifact_a).returncode, 0)
        self.assertEqual(self.promote(artifact_b, SHA_B).returncode, 0)
        self.assertEqual(self.installed_label(), "B")
        retained = Path(str(self.current) + ".artifacts")
        identities = (self.artifact_identity(artifact_a), self.artifact_identity(artifact_b, SHA_B))
        for identity in identities:
            archive = retained / (identity + ".tar.gz")
            self.verify_checksum(archive, retained / (identity + ".sha256"))
            self.assert_archive_private(archive)
        legacy = [p for p in retained.glob("*.tar.gz") if p.stem.removesuffix(".tar") not in identities]
        self.assertTrue(legacy, "first deployment must preserve a secret-free legacy rollback artifact")
        for archive in legacy:
            self.verify_checksum(archive, archive.with_name(archive.name.removesuffix(".tar.gz") + ".sha256"))
            self.assert_archive_private(archive)
            with tarfile.open(archive) as tar:
                label = next(m for m in tar.getmembers() if m.name.removeprefix("./") == "lib/app/LABEL")
                self.assertEqual(tar.extractfile(label).read(), b"legacy")
        self.assert_no_private_retention()

    def test_distinct_builds_of_same_commit_retain_both_exact_immutable_artifacts(self):
        artifact_a = self.package(SHA_A, "A")
        artifact_b = self.package(SHA_A, "rebuilt-A")
        identity_a = self.artifact_identity(artifact_a)
        identity_b = self.artifact_identity(artifact_b)
        self.assertNotEqual(identity_a, identity_b)
        result_a = self.promote(artifact_a)
        result_b = self.promote(artifact_b, DEPLOY_RUN_ID="same-commit-rebuild")
        self.assertEqual(result_a.returncode, 0, result_a.stderr)
        self.assertEqual(result_b.returncode, 0, result_b.stderr)
        self.assertEqual(self.installed_label(), "rebuilt-A")
        self.assertEqual((self.current / "RELEASE_ID").read_text().strip(), SHA_A)
        self.assertEqual((self.current / "ARTIFACT_ID").read_text().strip(), identity_b)
        retained = Path(str(self.current) + ".artifacts")
        for artifact, identity in ((artifact_a, identity_a), (artifact_b, identity_b)):
            archive = retained / (identity + ".tar.gz")
            self.assertEqual(archive.read_bytes(), (artifact / f"release-{SHA_A}.tar.gz").read_bytes())
            self.verify_checksum(archive, retained / (identity + ".sha256"))
            self.assert_archive_private(archive)

    def test_corrupt_retained_identity_is_rejected_without_overwriting_immutable_archive(self):
        artifact = self.package()
        self.assertEqual(self.promote(artifact).returncode, 0)
        identity = self.artifact_identity(artifact)
        retained = Path(str(self.current) + ".artifacts", identity + ".tar.gz")
        damaged = retained.read_bytes() + b"tampered retained bytes"
        retained.write_bytes(damaged)
        self.events.unlink()
        before = (self.current / ".env").read_bytes()

        result = self.promote(artifact, DEPLOY_RUN_ID="retry-same-artifact")

        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(retained.read_bytes(), damaged)
        self.assertEqual(self.installed_label(), "A")
        self.assertEqual((self.current / ".env").read_bytes(), before)
        self.assertEqual(self.logged(), [])

    def test_release_eval_does_not_inherit_the_destination_lock_descriptor(self):
        artifact = self.package()
        result = self.promote(artifact, SEED_DEMO="true")
        self.assertEqual(result.returncode, 0, result.stderr)
        evaluations = [e for e in self.logged() if e["phase"] in ("migrate", "seed")]
        self.assertEqual([e["phase"] for e in evaluations], ["migrate", "seed"])
        for evaluation in evaluations:
            self.assertFalse(evaluation["lock_fd_open"], "release/epmd children must not keep the deployment lock alive")

    def test_packaging_refuses_env_files_and_external_symlinks(self):
        for index, entry in enumerate((".env", "lib/app/.env.backup", "external-link")):
            with self.subTest(entry=entry):
                release = self.make_release(self.work / f"unsafe-release-{index}", "bad")
                if entry == "external-link":
                    (release / "lib/app/link").symlink_to(self.current / ".env")
                else:
                    (release / entry).write_text(ENV_SECRET)
                output = self.work / f"unsafe-output-{index}"
                result = self.run_script(PACKAGE, release, output, SHA_A)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse((output / f"release-{SHA_A}.tar.gz").exists())
                self.assertNotIn(ENV_SECRET, result.stdout + result.stderr)

    def test_corrupt_checksum_fails_before_configuration_or_service_mutation(self):
        artifact = self.package()
        with (artifact / f"release-{SHA_A}.tar.gz").open("ab") as archive:
            archive.write(b"corruption")
        before = (self.current / ".env").read_bytes()
        result = self.promote(artifact, CHAT_ENABLED="true", ANTHROPIC_API_KEY="synthetic-new-key")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.installed_label(), "legacy")
        self.assertEqual((self.current / ".env").read_bytes(), before)
        self.assertEqual(self.logged(), [])

    def malicious_artifact(self, directory, member):
        directory.mkdir()
        archive = directory / f"release-{SHA_A}.tar.gz"
        with tarfile.open(archive, "w:gz") as tar:
            identity = tarfile.TarInfo("RELEASE_ID")
            identity.size = len(SHA_A) + 1
            tar.addfile(identity, io.BytesIO((SHA_A + "\n").encode()))
            for name, payload, mode in (
                ("bin/residency_schedule", RELEASE_BIN.encode(), 0o755),
                ("lib/app/LABEL", b"bad", 0o644),
                ("releases/start_erl.data", b"synthetic runtime version\n", 0o644),
            ):
                valid = tarfile.TarInfo(name)
                valid.size = len(payload)
                valid.mode = mode
                tar.addfile(valid, io.BytesIO(payload))
            tar.addfile(member, io.BytesIO(b"x") if member.isfile() else None)
        digest = hashlib.sha256(archive.read_bytes()).hexdigest()
        (directory / f"release-{SHA_A}.sha256").write_text(f"{digest}  {archive.name}\n")

    def test_unsafe_archive_fails_before_env_source_or_service_mutation(self):
        for index, (name, kind) in enumerate((
            ("../escaped", tarfile.REGTYPE),
            ("/tmp/escaped-release-test", tarfile.REGTYPE),
            ("lib/app/.env", tarfile.REGTYPE),
            ("releases/COOKIE", tarfile.REGTYPE),
            ("lib/app/symlink", tarfile.SYMTYPE),
            ("lib/app/hardlink", tarfile.LNKTYPE),
            ("lib/app/fifo", tarfile.FIFOTYPE),
        )):
            with self.subTest(name=name):
                member = tarfile.TarInfo(name)
                member.type = kind
                member.size = 1 if kind == tarfile.REGTYPE else 0
                member.linkname = "../../../escaped" if kind in (tarfile.SYMTYPE, tarfile.LNKTYPE) else ""
                artifact = self.work / f"malicious-{index}"
                self.malicious_artifact(artifact, member)
                sentinel = self.work / "env-was-sourced"
                original = (self.current / ".env").read_text()
                (self.current / ".env").write_text(original + f"touch '{sentinel}'\n")
                try:
                    result = self.promote(artifact, CHAT_ENABLED="true")
                    self.assertNotEqual(result.returncode, 0)
                    self.assertFalse(sentinel.exists())
                    self.assertEqual(self.logged(), [])
                    self.assertEqual(self.installed_label(), "legacy")
                    self.assertEqual((self.current / ".env").read_text(), original + f"touch '{sentinel}'\n")
                finally:
                    (self.current / ".env").write_text(original)

    def test_migration_failure_leaves_original_running_files_and_configuration_intact(self):
        artifact = self.package()
        before = (self.current / ".env").read_bytes()
        result = self.promote(artifact, FAIL_MIGRATE_LABEL="A")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.installed_label(), "legacy")
        self.assertEqual((self.current / ".env").read_bytes(), before)
        self.assertEqual([e["phase"] for e in self.logged()], ["migrate"])
        self.assert_private_current()
        self.assert_no_private_retention()

    def test_missing_cookie_file_and_override_fails_before_service_mutation(self):
        artifact = self.package()
        (self.current / "releases/COOKIE").unlink()
        (self.current / ".env").write_text("DATABASE_URL=" + ENV_SECRET + "\n")
        before = (self.current / ".env").read_bytes()
        result = self.promote(artifact, CHAT_ENABLED="true")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.installed_label(), "legacy")
        self.assertEqual((self.current / ".env").read_bytes(), before)
        self.assertFalse((self.current / "releases/COOKIE").exists())
        self.assertEqual(self.logged(), [])

    def test_existing_env_cookie_override_works_without_generating_cookie_file(self):
        artifact = self.package()
        (self.current / "releases/COOKIE").unlink()
        before = (self.current / ".env").read_bytes()
        result = self.promote(artifact)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.installed_label(), "A")
        self.assertEqual((self.current / ".env").read_bytes(), before)
        self.assertFalse((self.current / "releases/COOKIE").exists())
        migration = next(e for e in self.logged() if e["phase"] == "migrate")
        self.assertFalse(migration["cookie_present"])
        self.assertTrue(migration["cookie_override_ok"])
        self.assert_no_private_retention()

    def test_each_swap_move_failure_keeps_or_recovers_original_tree(self):
        artifact = self.package()
        for failed_source in ("current", "candidate"):
            with self.subTest(failed_source=failed_source):
                self.events.unlink(missing_ok=True)
                Path(self.env["MOVE_FAILURE_MARKER"]).unlink(missing_ok=True)
                result = self.promote(artifact, FAIL_MOVE_SOURCE=failed_source)
                self.assertNotEqual(result.returncode, 0)
                self.assertTrue(Path(self.env["MOVE_FAILURE_MARKER"]).exists())
                self.assertEqual(self.installed_label(), "legacy")
                self.assert_private_current()
                self.assert_no_private_retention()

    def assert_recovery(self, failed_phase):
        artifact = self.package()
        result = self.promote(artifact, **{failed_phase: "A"})
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.installed_label(), "legacy")
        events = self.logged()
        self.assertEqual(events[0]["phase"], "migrate")
        self.assertIn({"phase": "restart", "label": "A"}, events)
        self.assertEqual(events[-2:], [{"phase": "restart", "label": "legacy"}, {"phase": "health", "label": "legacy"}])
        retained = Path(str(self.current) + ".artifacts", self.artifact_identity(artifact) + ".tar.gz")
        self.assertTrue(retained.is_file(), "failed artifact remains available for investigation")
        self.assert_private_current()
        self.assert_no_private_retention()

    def test_restart_failure_restores_original_and_checks_recovery_health(self):
        self.assert_recovery("FAIL_RESTART_LABEL")

    def test_health_failure_restores_original_and_checks_recovery_health(self):
        self.assert_recovery("FAIL_HEALTH_LABEL")

    def test_failed_recovery_health_is_reported_as_failure(self):
        artifact = self.package()
        result = self.promote(artifact, FAIL_RESTART_LABEL="A", FAIL_HEALTH_LABEL="legacy")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.installed_label(), "legacy")
        self.assertIn({"phase": "health", "label": "legacy"}, self.logged())
        self.assertRegex(result.stderr.lower(), r"recovery.*failed|rollback.*failed")
        self.assert_private_current()
        workspaces = list(Path(str(self.current) + ".deploy").glob("*"))
        self.assertTrue(workspaces, "failed recovery retains private operator recovery evidence")
        for workspace in workspaces:
            self.assertEqual(stat.S_IMODE(workspace.stat().st_mode), 0o700)
            for private in workspace.rglob("*"):
                if private.name in (".env", "COOKIE"):
                    self.assertEqual(stat.S_IMODE(private.stat().st_mode), 0o600)

    def fifo(self, name):
        path = self.work / name
        os.mkfifo(path, 0o600)
        descriptor = os.open(path, os.O_RDWR | os.O_NONBLOCK)
        self.addCleanup(os.close, descriptor)
        return path, descriptor

    def await_fifo(self, descriptor):
        self.assertTrue(select.select([descriptor], [], [], 5)[0], "deployment never reached synchronization point")
        self.assertTrue(os.read(descriptor, 4096))

    def launch(self, env):
        self.assertTrue(PROMOTE.is_file(), "missing required release script: promote_release.sh")
        process = subprocess.Popen(["bash", str(PROMOTE)], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, start_new_session=True)
        self.addCleanup(self.stop_process_group, process)
        return process

    def stop_process_group(self, process):
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.communicate(timeout=5)

    def test_same_destination_uses_real_stable_lock_through_health_and_unique_workspaces(self):
        artifact_a = self.package()
        artifact_b = self.package(SHA_B, "B")
        ready, ready_fd = self.fifo("ready")
        release, release_fd = self.fifo("release")
        notify, notify_fd = self.fifo("second-lock")
        health_ready, health_ready_fd = self.fifo("health-ready")
        health_release, health_release_fd = self.fifo("health-release")
        first = self.launch(self.promotion_env(artifact_a, GATE_LABEL="A", GATE_READY=str(ready), GATE_RELEASE=str(release), GATE_HEALTH_LABEL="A", HEALTH_READY=str(health_ready), HEALTH_RELEASE=str(health_release)))
        self.await_fifo(ready_fd)

        with Path(str(self.current) + ".deploy.lock").open("a") as stable_lock:
            with self.assertRaises(BlockingIOError):
                fcntl.flock(stable_lock, fcntl.LOCK_EX | fcntl.LOCK_NB)

        second = self.launch(self.promotion_env(artifact_b, SHA_B, FLOCK_NOTIFY=str(notify)))
        self.await_fifo(notify_fd)
        self.assertEqual(self.installed_label(), "legacy")
        os.write(release_fd, b"continue\n")
        self.await_fifo(health_ready_fd)
        with Path(str(self.current) + ".deploy.lock").open("a") as stable_lock:
            with self.assertRaises(BlockingIOError):
                fcntl.flock(stable_lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        self.assertFalse(any(e["phase"] == "migrate" and e["label"] == "B" for e in self.logged()))
        os.write(health_release_fd, b"continue\n")
        for process in (first, second):
            _, stderr = process.communicate(timeout=15)
            self.assertEqual(process.returncode, 0, stderr)
        events = self.logged()
        self.assertEqual([(e["phase"], e["label"]) for e in events], [
            ("migrate", "A"), ("restart", "A"), ("health", "A"),
            ("migrate", "B"), ("restart", "B"), ("health", "B"),
        ])
        migrations = [e for e in events if e["phase"] == "migrate"]
        self.assertNotEqual(migrations[0]["path"], migrations[1]["path"])
        self.assertEqual(self.installed_label(), "B")

    def test_different_destinations_have_independent_locks(self):
        artifact = self.package()
        demo = self.work / "demo"
        self.make_installed(demo)
        ready, ready_fd = self.fifo("ready")
        release, release_fd = self.fifo("release")
        first = self.launch(self.promotion_env(artifact, GATE_LABEL="A", GATE_READY=str(ready), GATE_RELEASE=str(release)))
        self.await_fifo(ready_fd)
        try:
            result = self.promote(artifact, install=demo, SEED_DEMO="true")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(self.installed_label(demo), "A")
            self.assertEqual(self.installed_label(), "legacy")
        finally:
            os.write(release_fd, b"continue\n")
            first.communicate(timeout=15)
        self.assertEqual(first.returncode, 0)


class ReleaseWorkflowTest(unittest.TestCase):
    def test_workflow_builds_once_promotes_same_artifact_and_serializes_each_destination(self):
        deploy = (ROOT / ".github/workflows/deploy.yml").read_text()
        jobs = dict(re.findall(r"^  ([a-zA-Z_][\w-]*):\n(.*?)(?=^  [a-zA-Z_][\w-]*:\n|\Z)", deploy, re.M | re.S))
        self.assertIn("build", jobs)
        self.assertIn("deploy", jobs)
        self.assertEqual(len(re.findall(r"\bmix release\b", deploy)), 1)
        self.assertEqual(len(re.findall(r"\bmix assets\.deploy\b", deploy)), 1)
        self.assertRegex(jobs["build"], r"needs:\s*(?:test|\[[^\]]*test[^\]]*\])")
        self.assertNotIn("secrets.", jobs["build"])
        self.assertIn("deploy/package_release.sh", jobs["build"])
        self.assertRegex(jobs["deploy"], r"needs:\s*\[[^\]]*test[^\]]*build[^\]]*\]")
        self.assertNotRegex(jobs["deploy"], r"\bmix (?:release|assets\.deploy|compile|deps\.get)\b")
        uploaded = re.search(r"uses: actions/upload-artifact@[^\n]+\n.*?name:\s*([^\n]+)", jobs["build"], re.S)
        downloaded = re.search(r"uses: actions/download-artifact@[^\n]+\n.*?name:\s*([^\n]+)", jobs["deploy"], re.S)
        self.assertIsNotNone(uploaded)
        self.assertIsNotNone(downloaded)
        self.assertEqual(uploaded.group(1).strip(), downloaded.group(1).strip())
        self.assertIn("matrix.target", jobs["deploy"])
        self.assertRegex(jobs["deploy"], r"(?s)concurrency:.*?group:.*?matrix\.target.*?cancel-in-progress:\s*false")
        self.assertIn("deploy/promote_release.sh", jobs["deploy"])
        for name in ("ci.yml", "deploy.yml"):
            workflow = (ROOT / ".github/workflows" / name).read_text()
            self.assertRegex(workflow, r"python3? -m unittest discover -s test/deploy -p ['\"]\*_test\.py['\"]")


if __name__ == "__main__":
    unittest.main()
