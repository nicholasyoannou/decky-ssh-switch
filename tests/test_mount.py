"""Exercise mount scripts with fake SSHFS commands; no mounts or network calls."""

import json
import os
from contextlib import contextmanager
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(os.name == "posix" and shutil.which("bash"), "Requires Bash on Linux/macOS")
class UnixMountTests(unittest.TestCase):
    @contextmanager
    def computer(self, platform):
        with tempfile.TemporaryDirectory(prefix="ssh switch ") as temporary:
            root = Path(temporary).resolve()
            folder = root / "mount space ' quote"
            folder.mkdir()
            log = root / "calls.jsonl"
            state = root / "mounted.json"
            state.write_text("{}")
            fake = root / "fake"
            fake.write_text(f"#!{sys.executable}\n" + """
import json, os, sys
from pathlib import Path
name = Path(sys.argv[0]).name
state = Path(os.environ['MOUNT_STATE'])
mounts = json.loads(state.read_text())
if name == 'uname': print(os.environ['MOUNT_PLATFORM'])
elif name == 'findmnt':
    if os.environ.get('MOUNT_QUERY_FAILURE'): sys.exit(2)
    folder = sys.argv[sys.argv.index('--mountpoint') + 1]
    if folder not in mounts: sys.exit(1)
    print(mounts[folder] + ' fuse.sshfs')
elif name == 'mount':
    if os.environ.get('MOUNT_QUERY_FAILURE'): sys.exit(2)
    for folder, identity in mounts.items(): print(identity + ' on ' + folder + ' (nfs)')
else:
    with open(os.environ['MOUNT_LOG'], 'a') as stream: stream.write(json.dumps([name] + sys.argv[1:]) + '\\n')
    if name == 'sshfs':
        if os.environ.get('MOUNT_FAILURE'): sys.exit(1)
        mounts[sys.argv[2]] = str(len(mounts) + 100) + ' ' + sys.argv[1]
    elif name in ('fusermount3', 'umount'):
        if sys.argv[-1] == os.environ.get('MOUNT_BUSY_FOLDER'): sys.exit(1)
        mounts.pop(sys.argv[-1], None)
    state.write_text(json.dumps(mounts))
""")
            fake.chmod(0o755)
            for command in ("uname", "sshfs", "ssh", "findmnt", "mount", "fusermount3", "umount"):
                (root / command).symlink_to(fake)
            env = {**os.environ, "PATH": str(root) + os.pathsep + os.environ["PATH"], "MOUNT_PLATFORM": platform,
                   "MOUNT_STATE": str(state), "MOUNT_LOG": str(log), "HOME": str(root / "home"), "XDG_STATE_HOME": str(root / "state")}
            yield root, folder, log, state, env

    def records(self, root):
        return sorted(root.rglob("mount.*"))

    def calls(self, log):
        return [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []

    def run_mount(self, platform="Linux", address="192.0.2.10", port="22", remote=None, occupied=False, nonempty=False, failure=False, unmount=False):
        with self.computer(platform) as (root, folder, log, state, env):
            if nonempty:
                (folder / "existing.txt").write_text("keep")
            if occupied:
                state.write_text(json.dumps({str(folder): "another filesystem"}))
            if failure:
                env["MOUNT_FAILURE"] = "1"
            script = ROOT / "mount" / ("mount-linux.sh" if platform == "Linux" else "mount-macos.sh")
            args = ["bash", str(script)] + (["--unmount", str(folder)] if unmount else [])
            remote = remote or "/run/media/deck/My SD ' $(touch NEVER_CREATE)"
            result = subprocess.run(args, input=f"{address}\n{port}\ndeck\n{remote}\n{folder}\n", env=env, cwd=root, capture_output=True, text=True)
            calls = self.calls(log)
            self.assertFalse((root / "NEVER_CREATE").exists())
            if nonempty:
                self.assertEqual((folder / "existing.txt").read_text(), "keep")
            records = self.records(root)
            self.assertEqual(len(records), int(result.returncode == 0 and not unmount))
            if records:
                self.assertEqual(records[0].read_text().splitlines()[0], str(folder))
                self.assertEqual(records[0].stat().st_mode & 0o777, 0o600)
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

    def test_ipv6_address_is_refused_with_a_usable_alternative(self):
        # SSH Switch lists IPv6 addresses, but sshfs splits host from path on a
        # colon, so one pasted here must be named and redirected, not just rejected.
        result, calls, _, _ = self.run_mount(address="2a04:201:74de:f300:3e22:7fff:feae:2543")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(calls, [])
        self.assertIn("IPv6", result.stderr)
        self.assertIn("steamdeck.local", result.stderr)

    def test_a_bad_address_fails_before_the_later_prompts(self):
        result, _, _, _ = self.run_mount(address="2a04:201:74de:f300:3e22:7fff:feae:2543")
        self.assertNotIn("Remote folder", result.stdout)
        self.assertNotIn("Local mount folder", result.stdout)

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

    def test_recorded_unmount_handles_multiple_mounts_busy_drives_and_retries(self):
        for platform in ("Linux", "Darwin"):
            with self.subTest(platform=platform), self.computer(platform) as (root, folder, log, state, env):
                suffix = "linux" if platform == "Linux" else "macos"
                second = root / "second $(touch NEVER_CREATE)"
                for destination in (folder, second):
                    result = subprocess.run(["bash", str(ROOT / f"mount/mount-{suffix}.sh")],
                                            input=f"\n\n\n\n{destination}\n", env=env, cwd=root, capture_output=True, text=True)
                    self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(len(self.records(root)), 2)
                self.assertIn("deck@steamdeck.local:/home/deck", self.calls(log)[0])
                args = ["bash", str(ROOT / f"mount/unmount-{suffix}.sh")]
                result = subprocess.run(args, env={**env, "MOUNT_BUSY_FOLDER": str(folder)}, capture_output=True, text=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(list(json.loads(state.read_text())), [str(folder)], result.stdout + result.stderr)
                self.assertEqual(len(self.records(root)), 1)
                self.assertEqual(self.records(root)[0].read_text().splitlines()[0], str(folder))
                result = subprocess.run(args, env=env, capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(json.loads(state.read_text()), {})
                self.assertEqual(self.records(root), [])
                count = len(self.calls(log))
                result = subprocess.run(args, env=env, capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("No recorded folders", result.stdout)
                self.assertEqual(len(self.calls(log)), count)
                self.assertTrue(folder.is_dir() and second.is_dir())
                self.assertFalse((root / "NEVER_CREATE").exists())

    def test_recorded_unmount_preserves_replacements_and_handles_missing_mounts(self):
        for platform in ("Linux", "Darwin"):
            for replacement in (False, True):
                with self.subTest(platform=platform, replacement=replacement), self.computer(platform) as (root, folder, log, state, env):
                    suffix = "linux" if platform == "Linux" else "macos"
                    result = subprocess.run(["bash", str(ROOT / f"mount/mount-{suffix}.sh")],
                                            input=f"\n\n\n\n{folder}\n", env=env, capture_output=True, text=True)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    current = {str(folder): "replacement filesystem"} if replacement else {}
                    state.write_text(json.dumps(current))
                    result = subprocess.run(["bash", str(ROOT / f"mount/unmount-{suffix}.sh")], env=env, capture_output=True, text=True)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(json.loads(state.read_text()), current)
                    self.assertEqual(len(self.calls(log)), 1, "No native unmount should run for a missing or replaced mount")
                    self.assertEqual(self.records(root), [])

    def test_unmount_keeps_records_when_inspection_fails(self):
        for platform in ("Linux", "Darwin"):
            with self.subTest(platform=platform), self.computer(platform) as (root, folder, log, state, env):
                suffix = "linux" if platform == "Linux" else "macos"
                result = subprocess.run(["bash", str(ROOT / f"mount/mount-{suffix}.sh")],
                                        input=f"\n\n\n\n{folder}\n", env=env, capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                before = self.records(root)[0].read_bytes()
                result = subprocess.run(["bash", str(ROOT / f"mount/unmount-{suffix}.sh")],
                                        env={**env, "MOUNT_QUERY_FAILURE": "1"}, capture_output=True, text=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.records(root)[0].read_bytes(), before)
                self.assertEqual(len(self.calls(log)), 1)

    def test_unmount_rejects_a_corrupt_record(self):
        for platform in ("Linux", "Darwin"):
            with self.subTest(platform=platform), self.computer(platform) as (root, folder, log, state, env):
                suffix = "linux" if platform == "Linux" else "macos"
                result = subprocess.run(["bash", str(ROOT / f"mount/mount-{suffix}.sh")],
                                        input=f"\n\n\n\n{folder}\n", env=env, capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.records(root)[0].write_text("relative/path\ninvalid record\n")
                result = subprocess.run(["bash", str(ROOT / f"mount/unmount-{suffix}.sh")], env=env, capture_output=True, text=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("Cannot read mount record", result.stderr)
                self.assertEqual(len(self.records(root)), 1)
                self.assertEqual(len(self.calls(log)), 1)
                self.assertIn(str(folder), json.loads(state.read_text()))

    def test_record_write_failure_prints_a_manual_unmount_command(self):
        for platform in ("Linux", "Darwin"):
            with self.subTest(platform=platform), self.computer(platform) as (root, folder, log, state, env):
                suffix = "linux" if platform == "Linux" else "macos"
                unavailable = root / "not-a-folder"
                unavailable.write_text("keep")
                env["XDG_STATE_HOME" if platform == "Linux" else "HOME"] = str(unavailable)
                result = subprocess.run(["bash", str(ROOT / f"mount/mount-{suffix}.sh")],
                                        input=f"\n\n\n\n{folder}\n", env=env, capture_output=True, text=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("its location could not be saved", result.stderr)
                self.assertIn("--unmount", result.stderr)
                self.assertEqual(self.records(root), [])
                self.assertIn(str(folder), json.loads(state.read_text()))
                self.assertEqual(unavailable.read_text(), "keep")


@unittest.skipUnless(os.name == "nt", "Requires native Windows process argument parsing")
class WindowsMountTests(unittest.TestCase):
    def test_double_click_launcher_handles_spaces_and_preserves_exit_codes(self):
        with tempfile.TemporaryDirectory(prefix="ssh switch & (launcher) ! ") as temporary:
            folder = Path(temporary)
            log = folder / "launched.txt"
            environment = {**os.environ, "SSH_SWITCH_LAUNCHER_LOG": str(log)}
            for name, parameter, arguments in (("mount-windows.cmd", "Configure", ["-Configure"]), ("unmount-windows.cmd", "Unmount", [])):
                (folder / name).write_bytes((ROOT / "mount" / name).read_bytes())
                for code in (0, 37):
                    with self.subTest(launcher=name, code=code):
                        self.check_launcher(folder, name, parameter, arguments, code, log, environment)

    def check_launcher(self, folder, name, parameter, arguments, code, log, environment):
        (folder / "mount-windows.ps1").write_text(
            f"param([switch] ${parameter})\n"
            f"if (-not ${parameter}) {{ exit 99 }}\n"
            "[IO.File]::WriteAllText($env:SSH_SWITCH_LAUNCHER_LOG, $PSScriptRoot)\n"
            f"exit {code}\n", encoding="utf-8")
        result = subprocess.run([os.environ["COMSPEC"], "/d", "/c", name, *arguments],
                                cwd=folder, env=environment, input="\n", capture_output=True, text=True, timeout=20)
        self.assertEqual(result.returncode, code, result.stdout + result.stderr)
        # PowerShell expands the short Windows paths used by hosted runners.
        self.assertTrue(folder.samefile(log.read_text()))
        self.assertEqual("Press any key to close." in result.stdout, code != 0)

    def test_powershell_setup_persistence_and_encrypted_settings(self):
        for shell in ("powershell", "pwsh"):
            if not shutil.which(shell):
                continue
            with self.subTest(shell=shell):
                result = subprocess.run([shell, "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", str(ROOT / "tests/test_mount_windows.ps1"), sys.executable], capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
