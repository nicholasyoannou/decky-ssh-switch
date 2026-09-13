"""Connection details are read from synthetic system output, never real keys."""

import base64
import hashlib
import json
import sys
import unittest
from types import SimpleNamespace
from unittest.mock import AsyncMock, Mock, patch

import main


class ConnectionTests(unittest.IsolatedAsyncioTestCase):
    async def get_info(self, config=None, network=None, mounts=None, config_code=0, mount_code=0):
        config = config if config is not None else "port 2222\nport 22\nport 22\nhostkey /test/ed25519\n"
        network = network if network is not None else [
            {"ifname": "wlan0", "flags": ["UP"], "addr_info": [
                {"local": "192.0.2.10", "scope": "global"},
                {"local": "127.0.0.1", "scope": "host"},
                {"local": "169.254.1.1", "scope": "global"},
                {"local": "invalid", "scope": "global"}]},
            {"ifname": "offline", "flags": [], "addr_info": [{"local": "192.0.2.11", "scope": "global"}]},
        ]
        mounts = mounts if mounts is not None else {"filesystems": [{"target": "/home"}, {"target": "/run/media/deck/My SD"}]}
        run = AsyncMock(side_effect=[(config_code, config, ""), (0, json.dumps(network), ""), (mount_code, json.dumps(mounts), "")])
        account = SimpleNamespace(pw_dir="/home/custom")
        with patch.object(main, "_account", return_value="custom"), \
             patch.dict(sys.modules, {"pwd": SimpleNamespace(getpwnam=Mock(return_value=account))}), \
             patch.object(main, "_run", run), \
             patch.object(main.socket, "gethostname", return_value="my-deck"), \
             patch.object(main.Path, "read_text", autospec=True, return_value="ssh-ed25519 cHVibGljLWtleQ== comment") as read:
            result = await main.Plugin().get_connection_info()
        self.assertTrue(all(str(call.args[0]).endswith(".pub") for call in read.call_args_list))
        self.assertTrue(all(call.args[0] in ("/usr/bin/sshd", "/usr/bin/ip", "/usr/bin/findmnt") for call in run.call_args_list))
        return result

    async def test_filters_addresses_and_reports_actual_ports_user_and_storage(self):
        info = await self.get_info()
        self.assertEqual(info["addresses"], [{"address": "192.0.2.10", "interface": "wlan0"}])
        self.assertEqual(info["ports"], [22, 2222])
        self.assertEqual(info["username"], "custom")
        self.assertEqual(info["folders"], [{"label": "Home", "path": "/home/custom"}, {"label": "External storage", "path": "/run/media/deck/My SD"}])
        digest = base64.b64encode(hashlib.sha256(b"public-key").digest()).decode().rstrip("=")
        self.assertEqual(info["fingerprint"], "SHA256:" + digest)

    async def test_no_network_does_not_invent_an_address(self):
        info = await self.get_info(network=[])
        self.assertEqual(info["addresses"], [])
        self.assertEqual(info["hostname"], "my-deck")

    async def test_failed_storage_listing_keeps_home(self):
        self.assertEqual(len((await self.get_info(mount_code=1))["folders"]), 1)

    async def test_config_failure_does_not_guess_port(self):
        with self.assertRaisesRegex(RuntimeError, "configuration"):
            await self.get_info(config_code=1)

    async def test_missing_key_or_port_is_reported(self):
        for config in ("port 22\n", "hostkey /test/ed25519\n"):
            with self.subTest(config=config), self.assertRaisesRegex(RuntimeError, "host key"):
                await self.get_info(config=config)

    async def test_unreadable_public_key_is_reported(self):
        with patch.object(main, "_account", return_value="deck"), \
             patch.dict(sys.modules, {"pwd": SimpleNamespace(getpwnam=lambda _: SimpleNamespace(pw_dir="/home/deck"))}), \
             patch.object(main, "_run", AsyncMock(return_value=(0, "port 22\nhostkey /test/key", ""))), \
             patch.object(main.Path, "read_text", side_effect=OSError):
            with self.assertRaisesRegex(RuntimeError, "host key"):
                await main.Plugin().get_connection_info()
