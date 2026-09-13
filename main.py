"""SteamOS SSH controls. No credentials or preferences are saved by the plugin."""

import asyncio
import base64
import ctypes
import hashlib
import ipaddress
import json
import os
import re
import socket
from pathlib import Path


SYSTEMCTL = "/usr/bin/systemctl"
SERVICE = "sshd.service"
SOCKETS = ("sshd.socket", "ssh.socket")
TIMEOUT = 20


def _require_root():
    if not hasattr(os, "geteuid") or os.geteuid() != 0:
        raise RuntimeError("SSH Switch needs Decky's root permission. Reinstall the plugin.")


def _account():
    # USER is root in a privileged Decky plugin; DECKY_USER is the host account.
    import pwd

    username = os.environ.get("DECKY_USER", "")
    if not re.fullmatch(r"[a-zA-Z_][a-zA-Z0-9_-]*\$?", username):
        raise RuntimeError("Decky did not provide a valid local account.")
    try:
        account = pwd.getpwnam(username)
    except KeyError:
        raise RuntimeError("The Decky account does not exist on this system.") from None
    if account.pw_uid < 1000:
        raise RuntimeError("Password changes are limited to the ordinary Decky user account.")
    return username


async def _run(*args, secret=None):
    """Only fixed commands call this module helper; it is not a Decky RPC method."""
    # Decky's frozen Python prepends its bundled libraries to LD_LIBRARY_PATH.
    # SteamOS system tools must use their own OpenSSL/systemd dependencies.
    environment = {**os.environ, "LC_ALL": "C", "SYSTEMD_PAGER": "cat"}
    original_library_path = environment.pop("LD_LIBRARY_PATH_ORIG", None)
    if original_library_path:
        environment["LD_LIBRARY_PATH"] = original_library_path
    else:
        environment.pop("LD_LIBRARY_PATH", None)
    try:
        process = await asyncio.create_subprocess_exec(
            *args,
            stdin=asyncio.subprocess.PIPE if secret is not None else asyncio.subprocess.DEVNULL,
            stdout=asyncio.subprocess.DEVNULL if secret is not None else asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.DEVNULL if secret is not None else asyncio.subprocess.PIPE,
            env=environment,
        )
    except OSError:
        raise RuntimeError("A required SteamOS system command could not be started.") from None
    communication = asyncio.create_task(process.communicate(secret))
    try:
        stdout, stderr = await asyncio.wait_for(asyncio.shield(communication), TIMEOUT)
    except (asyncio.TimeoutError, asyncio.CancelledError) as error:
        if process.returncode is None:
            try:
                process.kill()
            except ProcessLookupError:
                pass
        await communication
        if isinstance(error, asyncio.CancelledError):
            raise
        raise RuntimeError("The system command timed out. Wait for the status to update before retrying.") from None
    return process.returncode, (stdout or b"").decode("utf-8", "replace"), (stderr or b"").decode("utf-8", "replace")


async def _unit(name):
    code, output, _ = await _run(
        SYSTEMCTL, "show", "--no-pager",
        "--property=LoadState,ActiveState,UnitFileState,SubState", name,
    )
    values = dict(line.split("=", 1) for line in output.splitlines() if "=" in line)
    if values.get("LoadState") == "not-found":
        return None
    if code != 0 or not all(key in values for key in ("LoadState", "ActiveState", "UnitFileState", "SubState")):
        raise RuntimeError("Could not read SSH state from systemd. This plugin requires SteamOS.")
    return values


async def _status():
    username = _account()
    unit = await _unit(SERVICE)
    if unit is None:
        raise RuntimeError("The SteamOS SSH service (sshd.service) is not installed.")
    # A socket can reopen SSH after the daemon is stopped. Do not claim SSH is
    # off or modify a custom socket setup using service-only controls.
    for name in SOCKETS:
        socket = await _unit(name)
        if socket and (
            socket["ActiveState"] not in ("inactive", "failed")
            or socket["UnitFileState"] in ("enabled", "enabled-runtime", "linked", "linked-runtime")
        ):
            raise RuntimeError(f"{name} controls SSH on this system. SSH Switch supports the standard SteamOS sshd.service setup; disable socket activation before using its switches.")
    state = unit["ActiveState"]
    boot_state = unit["UnitFileState"]
    return {
        "username": username,
        "running": state in ("active", "reloading"),
        "startup": boot_state == "enabled",
        "active_state": state,
        "boot_state": boot_state,
        "masked": unit["LoadState"] == "masked" or boot_state in ("masked", "masked-runtime"),
        "transitioning": state in ("activating", "deactivating", "maintenance", "refreshing"),
    }


async def _change(action):
    code, _, _ = await _run(SYSTEMCTL, "--no-ask-password", action, SERVICE)
    if code != 0:
        raise RuntimeError(f"Could not {action} SSH. Check 'systemctl status sshd.service' in Desktop Mode.")


async def _connection_info():
    import pwd

    username = _account()
    home = pwd.getpwnam(username).pw_dir
    code, output, _ = await _run("/usr/bin/sshd", "-T")
    if code != 0:
        raise RuntimeError("Could not read the SSH configuration. Enable SSH, then reopen this dialog.")
    settings = [parts for line in output.splitlines() if len(parts := line.split(None, 1)) == 2]
    ports = sorted({int(value) for key, value in settings if key == "port"})
    fingerprint = None
    for key, value in settings:
        if key != "hostkey":
            continue
        try:
            # Only public keys are read; private host keys never enter an RPC.
            fields = Path(value + ".pub").read_text(encoding="ascii").split()
            if len(fields) >= 2 and fields[0] == "ssh-ed25519":
                digest = hashlib.sha256(base64.b64decode(fields[1], validate=True)).digest()
                fingerprint = "SHA256:" + base64.b64encode(digest).decode("ascii").rstrip("=")
                break
        except (OSError, ValueError, UnicodeError):
            continue
    if not ports or not fingerprint:
        raise RuntimeError("No SSH port or Ed25519 host key was found. Enable SSH, then reopen this dialog.")

    code, output, _ = await _run("/usr/bin/ip", "-j", "-4", "addr", "show", "scope", "global")
    if code != 0:
        raise RuntimeError("Could not read the Deck's network addresses.")
    addresses = []
    for interface in json.loads(output):
        if "UP" not in interface.get("flags", []):
            continue
        for entry in interface.get("addr_info", []):
            address = entry.get("local", "")
            try:
                parsed = ipaddress.IPv4Address(address)
            except ipaddress.AddressValueError:
                continue
            if entry.get("scope") == "global" and not parsed.is_loopback and not parsed.is_link_local:
                addresses.append({"address": address, "interface": interface["ifname"]})

    folders = [{"label": "Home", "path": home}]
    code, output, _ = await _run("/usr/bin/findmnt", "--json", "--list", "--output", "TARGET")
    if code == 0:
        for entry in json.loads(output).get("filesystems", []):
            target = entry.get("target", "")
            if target.startswith("/run/media/"):
                folders.append({"label": "External storage", "path": target})
    return {
        "username": username, "hostname": socket.gethostname(), "addresses": addresses,
        "ports": ports, "folders": folders, "fingerprint": fingerprint,
    }


def _boolean(value):
    if type(value) is not bool:
        raise ValueError("The switch value must be true or false.")


def _hash_password(password):
    """Use SteamOS libcrypt, without imposing password quality or length rules."""
    # crypt accepts C strings: reject NUL instead of silently truncating a password.
    if "\x00" in password:
        raise ValueError("The Linux password API cannot represent a NUL character.")
    try:
        phrase = password.encode("utf-8")
    except UnicodeEncodeError:
        raise ValueError("The Linux password API requires valid UTF-8 text.") from None
    try:
        library = ctypes.CDLL("libcrypt.so.1")
        libc = ctypes.CDLL(None)
        gensalt = library.crypt_gensalt_rn
        crypt = library.crypt_ra
    except (OSError, AttributeError):
        raise RuntimeError("SteamOS's password hashing library (libcrypt) is unavailable.") from None
    gensalt.argtypes = [ctypes.c_char_p, ctypes.c_ulong, ctypes.c_char_p, ctypes.c_int, ctypes.c_void_p, ctypes.c_int]
    gensalt.restype = ctypes.c_char_p
    crypt.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.POINTER(ctypes.c_void_p), ctypes.POINTER(ctypes.c_int)]
    crypt.restype = ctypes.c_char_p
    libc.free.argtypes = [ctypes.c_void_p]
    libc.free.restype = None
    salt = ctypes.create_string_buffer(192)
    # NULL prefix selects libcrypt's current default hashing algorithm.
    if not gensalt(None, 0, os.urandom(32), 32, salt, len(salt)):
        raise RuntimeError("The system could not prepare a password hash.")
    data = ctypes.c_void_p()
    size = ctypes.c_int()
    try:
        hashed = crypt(phrase, salt.value, ctypes.byref(data), ctypes.byref(size))
        if not hashed or hashed.startswith(b"*"):
            raise RuntimeError("The Linux password library could not represent this password.")
        return hashed.decode("ascii")
    finally:
        if data.value:
            ctypes.memset(data, 0, size.value)
            libc.free(data)


class Plugin:
    def __init__(self):
        self._lock = asyncio.Lock()

    async def get_status(self):
        async with self._lock:
            return await _status()

    async def get_connection_info(self):
        async with self._lock:
            return await _connection_info()

    async def set_enabled(self, enabled):
        _boolean(enabled)
        _require_root()
        async with self._lock:
            before = await _status()
            if enabled and before["masked"]:
                raise RuntimeError("SSH is masked by the system. Unmask sshd.service in Desktop Mode before enabling it.")
            if before["transitioning"]:
                raise RuntimeError("SSH is changing state. Wait a moment before retrying.")
            await _change("start" if enabled else "stop")
            after = await _status()
            if after["running"] != enabled or after["transitioning"]:
                raise RuntimeError("SSH did not reach the requested state. Wait for the status to update before retrying.")
            return after

    async def set_startup(self, enabled):
        _boolean(enabled)
        _require_root()
        async with self._lock:
            before = await _status()
            if enabled and before["masked"]:
                raise RuntimeError("SSH is masked by the system. Unmask sshd.service in Desktop Mode before enabling startup.")
            # Deliberately no --now: boot preference and runtime state are independent.
            await _change("enable" if enabled else "disable")
            after = await _status()
            if after["startup"] != enabled:
                raise RuntimeError("SSH startup did not reach the requested state. Wait for the status to update before retrying.")
            return after

    async def set_password(self, password):
        _require_root()
        if not isinstance(password, str):
            raise ValueError("The password must be text.")
        if not password.strip():
            raise ValueError("The password cannot be blank.")
        async with self._lock:
            username = _account()
            executable = next((p for p in ("/usr/bin/chpasswd", "/usr/sbin/chpasswd") if Path(p).is_file()), None)
            if executable is None:
                raise RuntimeError("The system password tool (chpasswd) is not installed.")
            # Hash before using chpasswd's line protocol, so arbitrary password
            # punctuation/newlines cannot inject another account update. -e also
            # avoids imposing PAM password-quality rules on the user's choice.
            hashed = await asyncio.to_thread(_hash_password, password)
            payload = f"{username}:{hashed}\n".encode("ascii")
            try:
                code, _, _ = await _run(executable, "--encrypted", secret=payload)
            finally:
                del payload
                del password
                del hashed
            if code != 0:
                raise RuntimeError("The system could not change the password. Check that the account is writable.")
            return {"username": username, "changed": True}

    async def _main(self):
        pass

    async def _unload(self):
        # Systemd owns SSH; closing/reloading Decky must not reset user choices.
        pass
