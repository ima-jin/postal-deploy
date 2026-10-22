"""Offline acceptance tests: no SSH, credentials, or Postal host required."""
import fcntl
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
IMAGE = "ghcr.io/ima-jin/postal-deploy:" + "a" * 40
OLD = {service: "sha256:" + digit * 64 for service, digit in
       (("web", "1"), ("worker", "2"), ("smtp", "3"))}

DOCKER = r"""#!/usr/bin/env python3
import json, os, pathlib, sys
p = pathlib.Path(os.environ["STATE"])
s = json.loads(p.read_text())
args = sys.argv[1:]
s["calls"].append(args)
def save():
    p.write_text(json.dumps(s))
save()
if args[0] == "inspect":
    print("invalid" if s.get("bad_image") else s["running"][args[-1]])
    sys.exit(0)
args = args[1:]
files = []
while args and args[0] == "-f":
    files.append(args[1])
    args = args[2:]
op = args[0]
if op == "ps":
    print({"missing": "", "replicated": "web\nweb2"}.get(s.get("containers"), args[-1]))
elif op == "config":
    sys.exit(1 if s.get("fail") == "config" else 0)
elif op == "pull":
    sys.exit(1 if s.get("fail") == "pull" else 0)
elif op == "up":
    s["ups"] += 1
    if s.get("fail") == "up" and s["ups"] == 1:
        # Model a partially applied compose up, not just an early failure.
        s["running"]["web"] = "partially-updated"
        save()
        sys.exit(1)
    if s.get("fail") == "rollback" and s["ups"] == 2:
        save()
        sys.exit(1)
    service = None
    for line in pathlib.Path(files[-1]).read_text().splitlines()[1:]:
        if line.startswith("  ") and not line.startswith("    "):
            service = line.strip().removesuffix(":")
        elif "image:" in line:
            s["running"][service] = line.split('"')[1]
    save()
else:
    sys.exit("unexpected docker command")
"""

CURL = r"""#!/usr/bin/env python3
import json, os, pathlib
p = pathlib.Path(os.environ["STATE"])
s = json.loads(p.read_text())
s["checks"] += 1
p.write_text(json.dumps(s))
print(s.get("health", "200"), end="")
"""


class DeployTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.path = Path(self.tmp.name)
        self.target = self.path / "postal"
        self.target.mkdir()
        self.base = self.target / "docker-compose.yml"
        self.base.write_text("operator-owned compose\n")
        self.postal = self.target / "postal.yml"
        self.postal.write_text("operator-owned postal config\n")
        self.state = self.path / "state.json"
        self.state.write_text(json.dumps({
            "calls": [], "ups": 0, "checks": 0, "running": OLD.copy(),
        }))
        self.bin = self.path / "bin"
        self.bin.mkdir()
        for name, source in (("docker", DOCKER), ("curl", CURL),
                             ("sleep", "#!/bin/sh\nexit 0\n")):
            file = self.bin / name
            file.write_text(source)
            file.chmod(0o755)
        self.env = {**os.environ, "PATH": f"{self.bin}:{os.environ['PATH']}",
                    "STATE": str(self.state)}

    def configure(self, **kwargs):
        state = self.read_state()
        state.update(kwargs)
        self.state.write_text(json.dumps(state))

    def read_state(self):
        return json.loads(self.state.read_text())

    def deploy(self, image=IMAGE, directory=None, services="web worker smtp",
               health="https://postal.example/login"):
        result = subprocess.run(
            ["bash", str(ROOT / "scripts/deploy.sh"), image,
             str(self.target) if directory is None else directory, services, health],
            env=self.env, capture_output=True, text=True, timeout=10,
        )
        self.assertEqual(self.base.read_text(), "operator-owned compose\n")
        self.assertEqual(self.postal.read_text(), "operator-owned postal config\n")
        return result

    def test_success_replaces_only_selected_images_and_keeps_rollback(self):
        result = self.deploy()
        self.assertEqual(result.returncode, 0, result.stderr)
        state = self.read_state()
        self.assertEqual(state["running"], dict.fromkeys(OLD, IMAGE))
        self.assertEqual(state["checks"], 1)
        rollback = (self.target / "docker-compose.imajin.rollback.yml").read_text()
        for image in OLD.values():
            self.assertIn(image, rollback)
        for call in state["calls"]:
            if "up" in call:
                self.assertIn("--no-deps", call)
                self.assertEqual(call[-3:], list(OLD))
            if "pull" in call:
                self.assertEqual(call[-3:], list(OLD))
        self.assertFalse(list(self.target.glob(".postal-*.??????")))

    def test_failure_restores_exact_running_images_including_first_deploy(self):
        for failure in ("health", "pull", "up"):
            with self.subTest(failure=failure):
                self.configure(fail=failure, health="503", running=OLD.copy(), ups=0)
                result = self.deploy()
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.read_state()["running"], OLD)
                self.assertIn("restoring previous image IDs", result.stderr)
                text = (self.target / "docker-compose.imajin.yml").read_text()
                for image in OLD.values():
                    self.assertIn(image, text)

    def test_redirect_or_network_failure_is_not_healthy(self):
        for status in ("302", "000"):
            with self.subTest(status=status):
                self.configure(health=status)
                self.assertNotEqual(self.deploy().returncode, 0)
                self.assertEqual(self.read_state()["running"], OLD)

    def test_rollback_failure_is_visible_and_deploy_stays_failed(self):
        self.configure(fail="rollback", health="500")
        result = self.deploy()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("CRITICAL: rollback failed", result.stderr)

    def test_invalid_config_or_missing_services_never_changes_override(self):
        override = self.target / "docker-compose.imajin.yml"
        override.write_text("previous override\n")
        cases = [
            {"image": "ghcr.io/ima-jin/postal-deploy:main"},
            {"image": IMAGE + "\n"},
            {"directory": "relative"},
            {"directory": str(self.path / "absent")},
            {"services": ""},
            {"services": "web web"},
            {"services": "web\nworker"},
            {"services": "web;touch"},
            {"services": "-web"},
            {"health": "https://postal.example/"},
            {"health": "https://user:password@postal.example/login"},
            {"health": "ftp://postal.example/login"},
        ]
        for case in cases:
            with self.subTest(case=case):
                self.assertNotEqual(self.deploy(**case).returncode, 0)
                self.assertEqual(override.read_text(), "previous override\n")
                self.assertEqual(self.read_state()["calls"], [])
        self.base.rename(self.target / "saved-compose")
        result = subprocess.run(
            ["bash", str(ROOT / "scripts/deploy.sh"), IMAGE, str(self.target),
             "web", "https://postal.example/login"],
            capture_output=True, text=True, env=self.env,
        )
        self.assertNotEqual(result.returncode, 0)

    def test_snapshot_and_compose_validation_fail_closed(self):
        for config in ({"containers": "missing"}, {"containers": "replicated"},
                       {"bad_image": True}, {"fail": "config"}):
            with self.subTest(config=config):
                self.configure(containers=None, bad_image=False, fail=None, **{
                    key: value for key, value in config.items()
                    if key not in ("containers", "bad_image", "fail")
                })
                self.configure(**config)
                self.assertNotEqual(self.deploy().returncode, 0)
                self.assertFalse((self.target / "docker-compose.imajin.yml").exists())
                self.assertEqual(self.read_state()["running"], OLD)

    def test_concurrent_deploy_is_rejected_before_docker(self):
        with (self.target / ".postal-deploy.lock").open("w") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.assertNotEqual(self.deploy().returncode, 0)
        self.assertEqual(self.read_state()["calls"], [])

    def test_argument_count_is_validated(self):
        result = subprocess.run(["bash", str(ROOT / "scripts/deploy.sh")],
                                capture_output=True)
        self.assertNotEqual(result.returncode, 0)


class SSHBoundaryTests(unittest.TestCase):
    def test_required_configuration_and_destination_validation(self):
        # Explicit non-credential sentinels; no keys are generated or used.
        env = {**os.environ, "POSTAL_HOST": "postal.example", "POSTAL_USER": "deploy",
               "POSTAL_COMPOSE_DIR": "/srv/postal", "POSTAL_SERVICES": "web worker smtp",
               "POSTAL_HEALTH_URL": "https://postal.example/login", "POSTAL_IMAGE": IMAGE,
               "POSTAL_DEPLOY_SSH_KEY": "TEST-NOT-A-KEY",
               "POSTAL_SSH_KNOWN_HOSTS": "TEST-NOT-A-HOST-KEY"}
        for name in [key for key in env if key.startswith("POSTAL_")]:
            with self.subTest(missing=name):
                result = subprocess.run(
                    ["bash", "scripts/deploy-ssh.sh"], cwd=ROOT,
                    env={**env, name: ""}, capture_output=True, text=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(name, result.stderr)
        for name, value in (("POSTAL_HOST", "-oProxyCommand=bad"),
                            ("POSTAL_USER", "user;bad"), ("POSTAL_PORT", "0"),
                            ("POSTAL_PORT", "65536"), ("POSTAL_PORT", "-1"),
                            ("POSTAL_PORT", "abc")):
            with self.subTest(name=name, value=value):
                result = subprocess.run(
                    ["bash", "scripts/deploy-ssh.sh"], cwd=ROOT,
                    env={**env, name: value}, capture_output=True)
                self.assertNotEqual(result.returncode, 0)

    def test_ssh_requires_pinned_host_and_quotes_remote_arguments(self):
        source = (ROOT / "scripts/deploy-ssh.sh").read_text()
        for required in ("StrictHostKeyChecking=yes", "BatchMode=yes",
                         "IdentitiesOnly=yes", "UserKnownHostsFile=",
                         "shlex.join", "unset POSTAL_DEPLOY_SSH_KEY POSTAL_SSH_KNOWN_HOSTS"):
            self.assertIn(required, source)
        self.assertNotIn("ssh-keyscan", source)


if __name__ == "__main__":
    unittest.main()
