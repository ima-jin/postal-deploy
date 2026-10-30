"""Contract tests complement actionlint; workflow_run must never trust PR code."""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]


class WorkflowTests(unittest.TestCase):
    def test_upstream_retains_exact_production_pin_with_additive_layer(self):
        self.assertEqual((ROOT / "Dockerfile").read_text().splitlines()[0],
                         "FROM ghcr.io/postalserver/postal:3.3.6@sha256:"
                         "4f96b2e527c5589e6b73e25aebf877917bba45b460f535ecfca527488745e926")
        self.assertIn("COPY --chown=postal:postal postal/ /opt/postal/app/",
                      (ROOT / "Dockerfile").read_text())

    def test_ci_builds_prs_but_publishes_only_main_pushes(self):
        ci = (ROOT / ".github/workflows/ci.yml").read_text()
        self.assertIn("pull_request:", ci)
        self.assertIn("branches: [main]", ci)
        guard = "github.event_name == 'push' && github.ref == 'refs/heads/main'"
        self.assertIn("if: " + guard, ci)
        self.assertIn("push: ${{ " + guard + " }}", ci)
        self.assertIn("packages: write", ci)
        self.assertIn("password: ${{ secrets.GITHUB_TOKEN }}", ci)
        for tag in ("${{ github.sha }}", "main"):
            self.assertIn("ghcr.io/ima-jin/postal-deploy:" + tag, ci)
        self.assertIn("needs: test", ci)
        self.assertIn("python3 -m unittest discover -s tests", ci)
        self.assertIn("/tmp/actionlint", ci)
        self.assertIn("load: true", ci)
        self.assertIn("bash scripts/test-admin.sh ghcr.io/ima-jin/postal-deploy:${{ github.sha }}", ci)

    def test_admin_tests_use_private_disposable_database_and_built_image(self):
        script = (ROOT / "scripts/test-admin.sh").read_text()
        self.assertIn('docker network create --internal "$network"', script)
        self.assertNotIn("--publish", script)
        self.assertIn('-e MAIN_DB_DATABASE=postal_test', script)
        self.assertIn('trap cleanup EXIT', script)
        self.assertIn('db:schema:load', script)
        self.assertIn('"$image"', script)
        self.assertIn('bundle exec ruby /imajin-tests/domains_test.rb', script)
        ignored = (ROOT / ".dockerignore").read_text()
        self.assertIn("!postal/**", ignored)

    def test_deploy_accepts_only_successful_trusted_main_push(self):
        deploy = (ROOT / ".github/workflows/deploy.yml").read_text()
        for guard in ("conclusion == 'success'", "event == 'push'",
                      "head_branch == 'main'",
                      "head_repository.full_name == github.repository"):
            self.assertIn("github.event.workflow_run." + guard, deploy)
        self.assertIn("workflows: [CI]", deploy)
        self.assertIn("branches: [main]", deploy)
        self.assertNotIn("workflow_dispatch:", deploy)
        self.assertNotIn("pull_request_target:", deploy)
        self.assertNotIn("secrets.GITHUB_TOKEN", deploy)
        self.assertIn("cancel-in-progress: false", deploy)

    def test_dev_then_production_environment_gate_same_built_sha(self):
        deploy = (ROOT / ".github/workflows/deploy.yml").read_text()
        dev, prod = deploy.split("  deploy-prod:")
        self.assertIn("environment: dev", dev)
        self.assertIn("needs: deploy-dev", prod)
        self.assertIn("environment: production", prod)
        for job in (dev, prod):
            self.assertIn("ref: ${{ github.event.workflow_run.head_sha }}", job)
            self.assertIn("POSTAL_IMAGE: ghcr.io/ima-jin/postal-deploy:"
                          "${{ github.event.workflow_run.head_sha }}", job)
            for name in ("POSTAL_HOST", "POSTAL_USER", "POSTAL_COMPOSE_DIR",
                         "POSTAL_SERVICES", "POSTAL_HEALTH_URL"):
                self.assertIn(f"{name}: ${{{{ vars.{name} }}}}", job)
            self.assertIn("run: bash scripts/deploy-ssh.sh", job)
        self.assertNotIn("/opt/postal", deploy)

    def test_actions_are_pinned_and_readme_documents_all_workflow_inputs(self):
        readme = (ROOT / "README.md").read_text()
        for file in (ROOT / ".github/workflows").glob("*.yml"):
            text = file.read_text()
            for reference in re.findall(r"uses: (\S+)", text):
                self.assertRegex(reference, r"^[\w/-]+@[0-9a-f]{40}$")
            for name in re.findall(r"(?:vars|secrets)\.(\w+)", text):
                self.assertIn(f"`{name}`", readme)
        self.assertIn("vault/seal", readme)
        self.assertIn("rollback", readme.lower())


if __name__ == "__main__":
    unittest.main()
