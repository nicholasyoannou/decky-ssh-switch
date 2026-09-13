"""No test touches real system services, accounts, or credentials."""

import asyncio
import ctypes
import os
import sys
import unittest
from types import SimpleNamespace
from unittest.mock import AsyncMock, Mock, mock_open, patch

import main


class FakeSystem:
    def __init__(self):
        self.active = "inactive"
        self.boot = "disabled"
        self.load = "loaded"
        self.calls = []
        self.failure = None
        self.no_effect = False
        self.socket = None

    async def run(self, *args, secret=None):
        self.calls.append((args, secret))
        if "show" in args:
            if args[-1] in main.SOCKETS:
                if self.socket and args[-1] == "sshd.socket":
                    active, boot = self.socket
                    return 0, f"LoadState=loaded\nActiveState={active}\nUnitFileState={boot}\nSubState=listening\n", ""
                return 0, "LoadState=not-found\nActiveState=inactive\nUnitFileState=\nSubState=dead\n", ""
            return 0, f"LoadState={self.load}\nActiveState={self.active}\nUnitFileState={self.boot}\nSubState=dead\n", ""
        action = "password" if secret is not None else args[-2]
        if action == self.failure:
            return 1, "", "private system details"
        if not self.no_effect:
            if action == "start": self.active = "active"
            if action == "stop": self.active = "inactive"
            if action == "enable": self.boot = "enabled"
            if action == "disable": self.boot = "disabled"
        return 0, "", ""

    def changes(self):
        return [args for args, _ in self.calls if "show" not in args]


class BackendTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.system = FakeSystem()
        self.plugin = main.Plugin()
        for target, replacement in (
            ("_run", self.system.run),
            ("_account", Mock(return_value="deck")),
            ("_require_root", Mock()),
            ("_hash_password", Mock(return_value="$y$synthetic-hash")),
            ("_password_hash", Mock(return_value="$y$synthetic-hash")),
        ):
            patcher = patch.object(main, target, replacement)
            patcher.start()
            self.addCleanup(patcher.stop)

    async def verified_change(self, password):
        result = await self.plugin.verify_current_password("current-example")
        main._hash_password.reset_mock()
        return await self.plugin.set_password(password, result["verification"])

    async def test_status_and_lifecycle_make_no_changes(self):
        await self.plugin._main()
        status = await self.plugin.get_status()
        await self.plugin._unload()
        self.assertFalse(status["running"])
        self.assertFalse(status["startup"])
        self.assertEqual(status["username"], "deck")
        self.assertEqual(self.system.changes(), [])

    async def test_runtime_switch_leaves_boot_preference_unchanged(self):
        self.system.boot = "enabled"
        self.assertTrue((await self.plugin.set_enabled(True))["running"])
        result = await self.plugin.set_enabled(False)
        self.assertFalse(result["running"])
        self.assertTrue(result["startup"])
        self.assertEqual([args[-2] for args in self.system.changes()], ["start", "stop"])

    async def test_boot_switch_leaves_runtime_unchanged(self):
        self.assertTrue((await self.plugin.set_startup(True))["startup"])
        self.assertEqual(self.system.active, "inactive")
        self.system.active = "active"
        result = await self.plugin.set_startup(False)
        self.assertFalse(result["startup"])
        self.assertTrue(result["running"])
        self.assertEqual([args[-2] for args in self.system.changes()], ["enable", "disable"])
        self.assertTrue(all("--now" not in args for args in self.system.changes()))

    async def test_runtime_only_enable_is_not_reported_as_boot_enabled(self):
        self.system.boot = "enabled-runtime"
        self.assertFalse((await self.plugin.get_status())["startup"])

    async def test_masked_service_is_not_unmasked(self):
        self.system.boot = self.system.load = "masked"
        self.assertTrue((await self.plugin.get_status())["masked"])
        for method in (self.plugin.set_enabled, self.plugin.set_startup):
            with self.assertRaisesRegex(RuntimeError, "masked"):
                await method(True)
        self.assertEqual(self.system.changes(), [])

    async def test_missing_service_is_reported(self):
        self.system.load = "not-found"
        with self.assertRaisesRegex(RuntimeError, "not installed"):
            await self.plugin.get_status()

    async def test_socket_activation_blocks_service_only_controls(self):
        for state in (("active", "disabled"), ("inactive", "enabled"), ("inactive", "enabled-runtime")):
            self.system.socket = state
            with self.assertRaisesRegex(RuntimeError, "socket"):
                await self.plugin.set_enabled(False)
            with self.assertRaisesRegex(RuntimeError, "socket"):
                await self.plugin.set_startup(False)
        self.assertEqual(self.system.changes(), [])

    async def test_unused_socket_does_not_block_standard_service(self):
        self.system.socket = ("inactive", "disabled")
        self.assertTrue((await self.plugin.set_enabled(True))["running"])

    async def test_transitions_block_competing_runtime_changes(self):
        self.system.active = "activating"
        self.assertTrue((await self.plugin.get_status())["transitioning"])
        with self.assertRaisesRegex(RuntimeError, "changing state"):
            await self.plugin.set_enabled(False)
        self.assertEqual(self.system.changes(), [])

    async def test_service_failure_is_not_reported_as_success(self):
        self.system.failure = "start"
        with self.assertRaisesRegex(RuntimeError, "Could not start"):
            await self.plugin.set_enabled(True)
        self.assertFalse((await self.plugin.get_status())["running"])

    async def test_post_change_state_is_verified(self):
        self.system.no_effect = True
        for method in (self.plugin.set_enabled, self.plugin.set_startup):
            with self.assertRaisesRegex(RuntimeError, "requested state"):
                await method(True)

    async def test_boolean_inputs_are_strict(self):
        for value in ("false", 0, 1, None, [], {}):
            for method in (self.plugin.set_enabled, self.plugin.set_startup):
                with self.assertRaises(ValueError):
                    await method(value)
        self.assertEqual(self.system.calls, [])

    async def test_mutations_require_root(self):
        with patch.object(main, "_require_root", side_effect=RuntimeError("root required")):
            for method, value in ((self.plugin.set_enabled, True), (self.plugin.set_startup, True), (self.plugin.verify_current_password, "example-only"), (self.plugin.set_password, "example-only")):
                with self.assertRaisesRegex(RuntimeError, "root required"):
                    await method(value)
        self.assertEqual(self.system.calls, [])

    async def test_only_password_hash_is_sent_to_stdin_for_host_user(self):
        password = "a':$(echo example) 🔒"
        with patch.object(main.Path, "is_file", return_value=True):
            result = await self.verified_change(password)
        self.assertEqual(result, {"username": "deck", "changed": True})
        args, secret = self.system.calls[-1]
        self.assertEqual(args, ("/usr/bin/chpasswd", "--encrypted"))
        self.assertEqual(secret, b"deck:$y$synthetic-hash\n")
        main._hash_password.assert_called_once_with(password)
        self.assertNotIn(password, repr(result))
        self.assertNotIn(password, repr(vars(self.plugin)))

    async def test_non_text_passwords_are_refused(self):
        for password in (None, 123, [], {}):
            with self.assertRaises(ValueError):
                await self.plugin.set_password(password)
        self.assertEqual(self.system.calls, [])

    async def test_blank_passwords_are_refused_before_hashing_or_updating(self):
        for password in ("", " ", "   ", "\t\r\n", "\u00a0", "\u2003"):
            with self.subTest(password=repr(password)):
                with self.assertRaisesRegex(ValueError, "cannot be blank"):
                    await self.plugin.set_password(password)
        main._hash_password.assert_not_called()
        self.assertEqual(self.system.calls, [])

    async def test_nonblank_passwords_keep_their_length_and_characters(self):
        for password in ("a", "short", "a" * 10000, "safe-pass\nroot:injected", "safe\rpass", "safe\tpass", "safe\x7fpass", " 🔒 : ", " a "):
            with self.subTest(password_length=len(password)), patch.object(main.Path, "is_file", return_value=True):
                self.assertTrue((await self.verified_change(password))["changed"])
                main._hash_password.assert_called_with(password)
                self.assertEqual(self.system.calls[-1][1], b"deck:$y$synthetic-hash\n")

    async def test_hashing_failure_never_updates_account(self):
        verification = (await self.plugin.verify_current_password("current-example"))["verification"]
        with patch.object(main, "_hash_password", side_effect=RuntimeError("hashing unavailable")), patch.object(main.Path, "is_file", return_value=True):
            with self.assertRaisesRegex(RuntimeError, "hashing unavailable"):
                await self.plugin.set_password("a", verification)
        self.assertEqual(self.system.calls, [])

    async def test_missing_password_tool_is_reported(self):
        with patch.object(main.Path, "is_file", return_value=False):
            with self.assertRaisesRegex(RuntimeError, "not installed"):
                await self.verified_change("example-only")
        self.assertEqual(self.system.calls, [])

    async def test_password_update_failure_is_generic(self):
        self.system.failure = "password"
        with patch.object(main.Path, "is_file", return_value=True):
            with self.assertRaises(RuntimeError) as caught:
                await self.verified_change("example-only")
        self.assertNotIn("example-only", str(caught.exception))
        self.assertNotIn("private system details", str(caught.exception))

    async def test_current_password_is_verified_without_retaining_or_returning_it(self):
        current = " current-example\n🔒 "
        result = await self.plugin.verify_current_password(current)
        self.assertTrue(result["verification"])
        main._hash_password.assert_called_once_with(current, "$y$synthetic-hash")
        self.assertNotIn(current, repr(result))
        self.assertNotIn("synthetic-hash", repr(result))
        self.assertNotIn(current, repr(vars(self.plugin)))
        self.assertEqual(self.system.calls, [])

    async def test_wrong_current_password_does_not_authorize_a_change(self):
        with patch.object(main, "_hash_password", return_value="$y$wrong-hash"):
            result = await self.plugin.verify_current_password("wrong-example")
        self.assertIsNone(result["verification"])
        self.assertTrue(result["password_available"])
        self.assertTrue((await self.plugin.set_password("new-example"))["verification_required"])
        self.assertEqual(self.system.calls, [])

    async def test_empty_locked_and_disabled_accounts_cannot_bypass_verification(self):
        for stored in ("", "!", "!!", "!$y$locked", "*", "*LK*"):
            with self.subTest(stored=stored), patch.object(main, "_password_hash", return_value=stored):
                result = await self.plugin.verify_current_password("")
                self.assertEqual(result, {"verification": None, "password_available": False})
                self.assertTrue((await self.plugin.set_password("new-example"))["verification_required"])
        main._hash_password.assert_not_called()
        self.assertEqual(self.system.calls, [])

    async def test_non_text_current_password_is_refused(self):
        for password in (None, 123, [], {}):
            with self.assertRaises(ValueError):
                await self.plugin.verify_current_password(password)
        main._hash_password.assert_not_called()

    async def test_missing_invalid_and_forged_verifications_cannot_change_password(self):
        for token in ("", "forged", None, 123, [], {}, "🔒"):
            await self.plugin.verify_current_password("current-example")
            result = await self.plugin.set_password("new-example", token)
            self.assertTrue(result["verification_required"])
        self.assertEqual(self.system.calls, [])

    async def test_verification_expires_after_five_minutes(self):
        with patch.object(main, "time", SimpleNamespace(monotonic=lambda: 100)):
            token = (await self.plugin.verify_current_password("current-example"))["verification"]
        with patch.object(main, "time", SimpleNamespace(monotonic=lambda: 400)):
            self.assertTrue((await self.plugin.set_password("new-example", token))["verification_required"])
        self.assertEqual(self.system.calls, [])

    async def test_verification_cannot_be_reused_by_concurrent_requests(self):
        token = (await self.plugin.verify_current_password("current-example"))["verification"]
        with patch.object(main.Path, "is_file", return_value=True):
            results = await asyncio.gather(*(self.plugin.set_password("new-example", token) for _ in range(2)))
        self.assertEqual(sum(result["changed"] for result in results), 1)
        self.assertEqual(len(self.system.changes()), 1)

    async def test_failed_update_consumes_verification(self):
        token = (await self.plugin.verify_current_password("current-example"))["verification"]
        self.system.failure = "password"
        with patch.object(main.Path, "is_file", return_value=True):
            with self.assertRaises(RuntimeError):
                await self.plugin.set_password("new-example", token)
        self.assertTrue((await self.plugin.set_password("new-example", token))["verification_required"])
        self.assertEqual(len(self.system.changes()), 1)

    async def test_a_later_verification_attempt_invalidates_the_previous_one(self):
        token = (await self.plugin.verify_current_password("current-example"))["verification"]
        with patch.object(main, "_hash_password", return_value="$y$wrong-hash"):
            await self.plugin.verify_current_password("wrong-example")
        self.assertTrue((await self.plugin.set_password("new-example", token))["verification_required"])
        self.assertEqual(self.system.calls, [])

    async def test_external_password_or_account_change_invalidates_verification(self):
        for target, value in (("_password_hash", "$y$changed-externally"), ("_account", "another_user")):
            token = (await self.plugin.verify_current_password("current-example"))["verification"]
            with patch.object(main, target, return_value=value):
                self.assertTrue((await self.plugin.set_password("new-example", token))["verification_required"])
        self.assertEqual(self.system.calls, [])

    async def test_unloading_discards_verification(self):
        token = (await self.plugin.verify_current_password("current-example"))["verification"]
        await self.plugin._unload()
        self.assertTrue((await self.plugin.set_password("new-example", token))["verification_required"])
        self.assertEqual(self.system.calls, [])

    async def test_status_failure_is_not_reported_as_off(self):
        with patch.object(main, "_run", AsyncMock(return_value=(1, "", "No system bus"))):
            with self.assertRaisesRegex(RuntimeError, "Could not read"):
                await self.plugin.get_status()

    async def test_requests_are_serialized(self):
        entered = asyncio.Event()
        release = asyncio.Event()
        original = self.system.run

        async def slow_run(*args, secret=None):
            if "start" in args:
                entered.set()
                await release.wait()
            return await original(*args, secret=secret)

        with patch.object(main, "_run", slow_run):
            first = asyncio.create_task(self.plugin.set_enabled(True))
            await entered.wait()
            second = asyncio.create_task(self.plugin.set_enabled(False))
            await asyncio.sleep(0)
            self.assertFalse(second.done())
            release.set()
            started, stopped = await asyncio.gather(first, second)
        self.assertTrue(started["running"])
        self.assertFalse(stopped["running"])


class AccountTests(unittest.TestCase):
    def account(self, name, uid):
        fake_pwd = SimpleNamespace(getpwnam=Mock(return_value=SimpleNamespace(pw_uid=uid)))
        with patch.dict(sys.modules, {"pwd": fake_pwd}), patch.dict(os.environ, {"DECKY_USER": name, "USER": "root"}):
            return main._account()

    def test_host_account_is_used_instead_of_root_environment(self):
        self.assertEqual(self.account("deck", 1000), "deck")
        self.assertEqual(self.account("another_user", 1001), "another_user")

    def test_root_system_and_malformed_accounts_are_refused(self):
        for name, uid in (("root", 0), ("daemon", 1), ("", 1000), ("deck\nroot", 1000), ("deck:root", 1000)):
            with self.assertRaises(RuntimeError):
                self.account(name, uid)

    def test_missing_host_account_is_refused(self):
        fake_pwd = SimpleNamespace(getpwnam=Mock(side_effect=KeyError))
        with patch.dict(sys.modules, {"pwd": fake_pwd}), patch.dict(os.environ, {"DECKY_USER": "missing"}):
            with self.assertRaisesRegex(RuntimeError, "does not exist"):
                main._account()


class HashTests(unittest.TestCase):
    def test_only_the_exact_local_account_hash_is_read(self):
        content = "root:root-hash:20000:0:99999:7:::\ndeck-other:other-hash:20000:0:99999:7:::\ndeck:deck-hash:20000:0:99999:7:::\n"
        with patch.object(main.Path, "open", mock_open(read_data=content)):
            self.assertEqual(main._password_hash("deck"), "deck-hash")

    def test_missing_malformed_and_unreadable_password_records_are_refused(self):
        for content in ("", "deck:hash\n", "other:hash:20000:0:99999:7:::\n"):
            with patch.object(main.Path, "open", mock_open(read_data=content)):
                with self.assertRaisesRegex(RuntimeError, "Could not read"):
                    main._password_hash("deck")
        with patch.object(main.Path, "open", side_effect=PermissionError("sensitive details")):
            with self.assertRaisesRegex(RuntimeError, "Could not read") as caught:
                main._password_hash("deck")
        self.assertNotIn("sensitive details", str(caught.exception))

    def test_nul_is_not_silently_truncated(self):
        with self.assertRaisesRegex(ValueError, "NUL"):
            main._hash_password("before\x00after")

    @unittest.skipUnless(sys.platform.startswith("linux"), "Uses SteamOS/Linux libcrypt")
    def test_real_hashes_accept_short_empty_long_and_control_characters(self):
        library = ctypes.CDLL("libcrypt.so.1")
        library.crypt.argtypes = [ctypes.c_char_p, ctypes.c_char_p]
        library.crypt.restype = ctypes.c_char_p
        for password in ("", "a", "password", "a" * 256, "\nroot:example\r\t\x7f 🔒"):
            with self.subTest(password_length=len(password)):
                hashed = main._hash_password(password)
                self.assertTrue(hashed.startswith("$"))
                self.assertNotRegex(hashed, r"[\s:]")
                self.assertEqual(library.crypt(password.encode(), hashed.encode()).decode(), hashed)
                self.assertNotEqual(library.crypt((password + "x").encode(), hashed.encode()).decode(), hashed)
                self.assertEqual(main._hash_password(password, hashed), hashed)
                self.assertNotEqual(main._hash_password(password + "x", hashed), hashed)

    @unittest.skipUnless(sys.platform.startswith("linux"), "Uses SteamOS/Linux libcrypt")
    def test_each_hash_has_a_fresh_salt(self):
        self.assertNotEqual(main._hash_password("a"), main._hash_password("a"))


class SubprocessTests(unittest.IsolatedAsyncioTestCase):
    async def test_system_commands_do_not_inherit_deckys_bundled_libraries(self):
        environment = {"PATH": os.environ.get("PATH", ""), "LD_LIBRARY_PATH": "/tmp/_MEI-decky"}
        process = SimpleNamespace(returncode=0, communicate=AsyncMock(return_value=(b"", b"")))
        with patch.dict(os.environ, environment, clear=True), patch.object(main.asyncio, "create_subprocess_exec", AsyncMock(return_value=process)) as launch:
            await main._run(main.SYSTEMCTL, "show", main.SERVICE)
        self.assertNotIn("LD_LIBRARY_PATH", launch.call_args.kwargs["env"])
        self.assertEqual(launch.call_args.kwargs["env"]["LC_ALL"], "C")

    async def test_original_system_library_path_is_restored_for_child_only(self):
        environment = {"LD_LIBRARY_PATH": "/tmp/_MEI-decky", "LD_LIBRARY_PATH_ORIG": "/usr/local/lib"}
        process = SimpleNamespace(returncode=0, communicate=AsyncMock(return_value=(b"", b"")))
        with patch.dict(os.environ, environment), patch.object(main.asyncio, "create_subprocess_exec", AsyncMock(return_value=process)) as launch:
            await main._run(main.SYSTEMCTL, "show", main.SERVICE)
            self.assertEqual(os.environ["LD_LIBRARY_PATH"], "/tmp/_MEI-decky")
        self.assertEqual(launch.call_args.kwargs["env"]["LD_LIBRARY_PATH"], "/usr/local/lib")
        self.assertNotIn("LD_LIBRARY_PATH_ORIG", launch.call_args.kwargs["env"])

    async def test_password_tool_output_is_discarded(self):
        result = await main._run(sys.executable, "-c", "import sys; data=sys.stdin.buffer.read(); sys.stdout.buffer.write(data); sys.stderr.buffer.write(data)", secret=b"synthetic-input")
        self.assertEqual(result, (0, "", ""))

    async def test_command_output_and_exit_code_are_read(self):
        result = await main._run(sys.executable, "-c", "import sys; print('ok'); sys.exit(3)")
        self.assertEqual(result[0], 3)
        self.assertEqual(result[1].strip(), "ok")

    async def test_timeout_terminates_and_reaps_child(self):
        with patch.object(main, "TIMEOUT", 0.1):
            with self.assertRaisesRegex(RuntimeError, "timed out"):
                await main._run(sys.executable, "-c", "import time; time.sleep(30)")

    async def test_cancellation_terminates_and_reaps_child(self):
        task = asyncio.create_task(main._run(sys.executable, "-c", "import time; time.sleep(30)"))
        await asyncio.sleep(0.1)
        task.cancel()
        with self.assertRaises(asyncio.CancelledError):
            await task


if __name__ == "__main__":
    unittest.main()
