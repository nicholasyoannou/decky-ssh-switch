"""Exercise mount scripts with fake SSHFS commands; no mounts or network calls."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(os.name == "posix" and shutil.which("bash"), "Requires Bash on Linux/macOS")
class UnixMountTests(unittest.TestCase):
    def run_mount(self, platform="Linux", address="192.0.2.10", port="22", remote=None, occupied=False, nonempty=False, failure=False, unmount=False):
        with tempfile.TemporaryDirectory(prefix="ssh switch ") as temporary:
            root = Path(temporary)
            folder = root / "mount space ' quote"
            folder.mkdir()
            if nonempty:
                (folder / "existing.txt").write_text("keep")
            log = root / "calls.jsonl"
            fake = root / "fake"
            fake.write_text(f"#!{sys.executable}\n" + """
import json, os, sys
from pathlib import Path
name = Path(sys.argv[0]).name
if name == 'uname': print(os.environ['MOUNT_PLATFORM'])
elif name == 'mountpoint': sys.exit(0 if os.environ['MOUNT_OCCUPIED'] == '1' else 1)
elif name == 'mount':
    if os.environ['MOUNT_OCCUPIED'] == '1': print('test on ' + os.environ['MOUNT_FOLDER'] + ' (nfs)')
else:
    with open(os.environ['MOUNT_LOG'], 'a') as stream: stream.write(json.dumps([name] + sys.argv[1:]) + '\\n')
    if name == 'sshfs' and os.environ['MOUNT_FAILURE'] == '1': sys.exit(1)
""")
            fake.chmod(0o755)
            for command in ("uname", "sshfs", "ssh", "mountpoint", "mount", "fusermount3", "umount"):
                (root / command).symlink_to(fake)
            env = {**os.environ, "PATH": str(root) + os.pathsep + os.environ["PATH"], "MOUNT_PLATFORM": platform,
                   "MOUNT_OCCUPIED": str(int(occupied)), "MOUNT_FAILURE": str(int(failure)), "MOUNT_FOLDER": str(folder), "MOUNT_LOG": str(log)}
            script = ROOT / "mount" / ("mount-linux.sh" if platform == "Linux" else "mount-macos.sh")
            args = ["bash", str(script)] + (["--unmount", str(folder)] if unmount else [])
            remote = remote or "/run/media/deck/My SD ' $(touch NEVER_CREATE)"
            result = subprocess.run(args, input=f"{address}\n{port}\ndeck\n{remote}\n{folder}\n", env=env, cwd=root, capture_output=True, text=True)
            calls = [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []
            self.assertFalse((root / "NEVER_CREATE").exists())
            if nonempty:
                self.assertEqual((folder / "existing.txt").read_text(), "keep")
            return result, calls, str(folder), remote

    def test_both_platforms_preserve_literal_remote_and_local_paths(self):
        for platform in ("Linux", "Darwin"):
            with self.subTest(platform=platform):
                result, calls, folder, remote = self.run_mount(platform=platform, port="02222")
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(len(calls), 1)
                self.assertEqual(calls[0][:5], ["sshfs", "deck@192.0.2.10:" + remote, folder, "-p", "2222"])
                self.assertIn("StrictHostKeyChecking=ask", calls[0])
                self.assertIn("HostKeyAlgorithms=ssh-ed25519", calls[0])
                self.assertNotIn("password_stdin", calls[0])

    def test_invalid_inputs_never_reach_sshfs(self):
        for changes in ({"address": "-oProxyCommand=bad"}, {"address": "host;touch NEVER_CREATE"}, {"port": "65536"}, {"port": "0"}, {"remote": "relative"}):
            with self.subTest(changes=changes):
                result, calls, _, _ = self.run_mount(**changes)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(calls, [])

    def test_occupied_and_nonempty_folders_are_preserved(self):
        for platform in ("Linux", "Darwin"):
            for changes in ({"occupied": True}, {"nonempty": True}):
                result, calls, _, _ = self.run_mount(platform=platform, **changes)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(calls, [])

    def test_failed_mount_is_not_reported_as_success(self):
        result, _, _, _ = self.run_mount(failure=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("Mounted at", result.stdout)

    def test_unmount_uses_native_tool_and_literal_path(self):
        for platform, command in (("Linux", "fusermount3"), ("Darwin", "umount")):
            result, calls, folder, _ = self.run_mount(platform=platform, unmount=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(calls, [[command, "-u", folder]] if platform == "Linux" else [[command, folder]])


@unittest.skipUnless(os.name == "nt", "Requires native Windows process argument parsing")
class WindowsMountTests(unittest.TestCase):
    def test_powershell_validation_quoting_and_host_verification(self):
        for shell in ("powershell", "pwsh"):
            if not shutil.which(shell):
                continue
            with self.subTest(shell=shell):
                result = subprocess.run([shell, "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", str(ROOT / "tests/test_mount_windows.ps1"), sys.executable], capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
