"""Exercise release publishing with a local fake gh; no GitHub API calls."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "release.sh"


@unittest.skipUnless(os.name == "posix" and shutil.which("bash"), "Release job runs on Linux")
class ReleaseTests(unittest.TestCase):
    def run_release(self, scenario="new", version="0.1.1", tag=None, missing_asset=False):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / "release").mkdir()
            if not missing_asset:
                for name in (f"ssh-switch-{version}.zip", f"ssh-switch-{version}-source.zip", "SHA256SUMS"):
                    (root / "release" / name).write_text("synthetic asset")
            fake = root / "gh"
            fake.write_text("""#!/usr/bin/env python3
import json, os, sys
with open(os.environ['GH_TEST_LOG'], 'a') as log:
    log.write(json.dumps(sys.argv[1:]) + '\\n')
command = sys.argv[2]
scenario = os.environ['GH_TEST_SCENARIO']
if command == 'view':
    if scenario in ('new', 'upload_failure'): sys.exit(1)
    print('false' if scenario == 'published' else 'true')
if command == 'upload' and scenario == 'upload_failure': sys.exit(1)
""")
            fake.chmod(0o755)
            log = root / "calls.jsonl"
            env = {**os.environ, "PATH": f"{root}{os.pathsep}{os.environ['PATH']}", "GH_TOKEN": "synthetic-token", "GH_REPO": "example/ssh-switch", "RELEASE_TAG": tag or f"v{version}", "RELEASE_VERSION": version, "GH_TEST_SCENARIO": scenario, "GH_TEST_LOG": str(log)}
            result = subprocess.run(["bash", str(SCRIPT)], cwd=root, env=env, capture_output=True, text=True)
            calls = [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []
            return result, calls

    def test_creates_draft_uploads_assets_then_publishes(self):
        result, calls = self.run_release()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([call[1] for call in calls], ["view", "create", "upload", "edit"])
        self.assertIn("--draft", calls[1])
        self.assertIn("--verify-tag", calls[1])
        self.assertIn("release/ssh-switch-0.1.1.zip", calls[2])
        self.assertIn("release/ssh-switch-0.1.1-source.zip", calls[2])
        self.assertIn("release/SHA256SUMS", calls[2])
        self.assertIn("--draft=false", calls[3])

    def test_existing_draft_can_be_resumed(self):
        result, calls = self.run_release("draft")
        self.assertEqual(result.returncode, 0)
        self.assertEqual([call[1] for call in calls], ["view", "upload", "edit"])

    def test_published_release_is_not_overwritten(self):
        result, calls = self.run_release("published")
        self.assertEqual(result.returncode, 0)
        self.assertEqual([call[1] for call in calls], ["view"])

    def test_failed_upload_does_not_publish(self):
        result, calls = self.run_release("upload_failure")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("edit", [call[1] for call in calls])

    def test_tag_mismatch_makes_no_github_calls(self):
        result, calls = self.run_release(tag="v9.0.0")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(calls, [])

    def test_missing_asset_makes_no_github_calls(self):
        result, calls = self.run_release(missing_asset=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(calls, [])

    def test_prerelease_is_not_marked_latest(self):
        result, calls = self.run_release(version="0.2.0-beta.1")
        self.assertEqual(result.returncode, 0)
        self.assertIn("--prerelease", calls[-1])
        self.assertIn("--latest=false", calls[-1])
