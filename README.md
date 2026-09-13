<p align="center">
  <img src="assets/logo.png" alt="SSH Switch" width="560">
</p>

# SSH Switch

A small Decky Loader plugin for Steam Deck:

- **SSH enabled** starts or stops SSH now.
- **Start at boot** enables or disables SSH at system startup, independently of whether it is running now.
- **Change password** verifies the current password, then asks for a new password and confirmation for the Linux account (normally `deck`). If no password is set yet, run `passwd` in Desktop Mode first.
- **Connect from computer** shows connection details for mounting the Deck's files on Windows, Linux or macOS.

## Screenshots

<p align="center">
  <a href="assets/screenshots/ssh-controls.png"><img src="assets/screenshots/ssh-controls.png" alt="SSH Switch on Steam Deck, showing SSH enabled and Start at boot" width="32%" align="top"></a>
  <a href="assets/screenshots/password-form.png"><img src="assets/screenshots/password-form.png" alt="SSH Switch password dialog on Steam Deck with masked example text and Save and Cancel buttons" width="66%" align="top"></a>
</p>

## Install

This plugin is made for SteamOS (Steam Deck) with OpenSSH (`sshd.service`) and Decky Loader installed. The plugin needs the `root` permission to control system services and change the local account password.

Install `ssh-switch-<version>.zip` from the repository's **Releases** page. The `-source.zip` archive is for development.

Copy the release ZIP to the Deck. Enable Developer Mode in Decky's settings, open its Developer page, and use **Install Plugin from ZIP File** to select it. If your Decky version only offers a ZIP URL, use a directly downloadable URL for the same release archive, or install manually below.

For a manual install, extract the ZIP in Desktop Mode. Copy the extracted `decky-ssh` folder into `~/homebrew/plugins/`, then restart.

## Mount files on your computer

Enable SSH and open **Connect from computer** on the Deck. Keep both devices on the same network.

The mounting helpers are included in [GitHub Releases](https://github.com/nicholasyoannou/decky-ssh-switch/releases/latest). Download the archive for your OS below and extract all files.

| Download | After extracting |
| --- | --- |
| **[Windows](https://github.com/nicholasyoannou/decky-ssh-switch/releases/latest/download/ssh-switch-mount-windows.zip)** | Double-click `mount-windows.cmd` |
| **[Linux](https://github.com/nicholasyoannou/decky-ssh-switch/releases/latest/download/ssh-switch-mount-linux.zip)** | Run `bash mount-linux.sh` in the extracted folder |
| **[macOS](https://github.com/nicholasyoannou/decky-ssh-switch/releases/latest/download/ssh-switch-mount-macos.zip)** | Run `bash mount-macos.sh` in the extracted folder |

Unmount helpers leave saved settings, local folders and unrelated drives alone. If a mount is busy, close files using it and retry.

### Windows

1. Double-click `mount-windows.cmd`. It opens PowerShell and installs missing [SSHFS-Win and WinFsp](https://github.com/winfsp/sshfs-win) dependencies through WinGet. Approve the administrator prompt if shown.
2. Enter your connection details. The defaults are `steamdeck` and one persistent `S:` drive. Separate Home, SD card and Root drives are optional and default to **No**.
3. Choose whether to **Save settings and password** (default **Yes**). The password is encrypted for your Windows account on this PC. Later runs reconnect using the saved setup.

- **Disconnect:** double-click `unmount-windows.cmd`. Closing the mounting script leaves the drives connected.
- **Change setup:** run `mount-windows.cmd -Configure`. To forget saved settings and the password, delete `%LOCALAPPDATA%\SSH Switch\mount-windows.xml`.

Keep the `.cmd` and `.ps1` files together. SSHFS-Win's network-drive provider does not verify the Deck's SSH fingerprint.

### Linux

1. Install SSHFS from your package manager, e.g. `sudo apt install sshfs` on Ubuntu/Debian.
2. Run `bash mount-linux.sh` in the extracted folder.
3. Enter the connection details shown on the Deck and choose a local folder. Compare the SSH fingerprint when prompted, then enter your Deck password.

**Disconnect:** run `bash unmount-linux.sh`. Mount locations are remembered; passwords are not saved.

### macOS

1. Install [FUSE-T and SSHFS](https://github.com/macos-fuse-t/fuse-t#installing-from-brew):

   ```sh
   brew install macos-fuse-t/homebrew-cask/fuse-t macos-fuse-t/homebrew-cask/sshfs-fuse-t
   ```

2. Run `bash mount-macos.sh` in the extracted folder.
3. Enter the connection details shown on the Deck and choose a local folder. Compare the SSH fingerprint when prompted, then enter your Deck password.

**Disconnect:** run `bash unmount-macos.sh`. Mount locations are remembered; passwords are not saved.

## Build and test

Requires Node.js 20+, PNPM 9.15.9 and Python 3.10+.

```sh
pnpm install --frozen-lockfile
pnpm test
pnpm run package
pnpm run verify-package
```

Release ZIPs are written to `release/`. Run `pnpm run clean` to remove generated files.

## CI/CD and releases

Publish the contents of this `decky-ssh` directory as the repository root. The workflow is `.github/workflows/build-release.yml`.

- Every branch push and pull request runs the tests, type-checks, builds and verifies all ZIPs. The archives and checksums are available as workflow artifacts for 14 days.
- Pushing a version tag such as `v0.2.1` runs the same checks, then creates a GitHub Release containing the plugin, source and three mounting helper ZIPs, plus `SHA256SUMS`. The tag must match `package.json`.
- Tags such as `v0.2.0-beta.1` produce prereleases. The workflow can also be run manually; selecting a version tag enables publishing, while selecting a branch only builds artifacts.

After committing and pushing this project to GitHub, publish the current version with:

```sh
git tag v0.2.1
git push origin v0.2.1
```

For subsequent releases, run `pnpm version patch` (or `minor` / `major`) in a clean Git checkout, then push the commit and generated tag with `git push origin HEAD --follow-tags`.

## Development references

- [Decky plugin template and packaging](https://github.com/SteamDeckHomebrew/decky-plugin-template)
- [Decky plugin runtime and host-account environment](https://github.com/SteamDeckHomebrew/decky-loader/blob/main/backend/decky_loader/plugin/sandboxed_plugin.py)
- [systemctl command semantics](https://www.freedesktop.org/software/systemd/man/latest/systemctl.html)
- [chpasswd documentation](https://github.com/shadow-maint/shadow/blob/master/man/chpasswd.8.xml)
- [Linux password hashing API](https://manpages.debian.org/testing/libcrypt-dev/crypt.3.en.html)
- [GitHub Actions workflow syntax](https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax)
