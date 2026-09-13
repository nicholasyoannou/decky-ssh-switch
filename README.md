<p align="center">
  <img src="assets/logo.png" alt="SSH Switch" width="560">
</p>

# SSH Switch

A small Decky Loader plugin for Steam Deck:

- **SSH enabled** starts or stops SSH now.
- **Start at boot** enables or disables SSH at system startup, independently of whether it is running now.
- **Set password** opens a dialog to change the user's Linux account password (normally `deck`).

## Screenshots

<p align="center">
  <img src="assets/screenshots/ssh-controls.png" alt="SSH Switch on Steam Deck, showing SSH enabled and Start at boot" width="300">
</p>
<p align="center">
  <img src="assets/screenshots/password-form.png" alt="SSH Switch password dialog on Steam Deck with masked example text and Save and Cancel buttons" width="680">
</p>

Captured on a Steam Deck in Steam's Big Picture interface.

## Install

This plugin is made for SteamOS (Steam Deck) with OpenSSH (`sshd.service`) and Decky Loader installed. The plugin needs the `root` permission to control system services and change the local account password.

Install `ssh-switch-<version>.zip` from the repository's **Releases** page. The `-source.zip` archive is for development.

Copy the release ZIP to the Deck. Enable Developer Mode in Decky's settings, open its Developer page, and use **Install Plugin from ZIP File** to select it. If your Decky version only offers a ZIP URL, use a directly downloadable URL for the same release archive, or install manually below.

For a manual install, extract the ZIP in Desktop Mode. Copy the extracted `decky-ssh` folder into `~/homebrew/plugins/`, then restart.

## Build and test

Node.js 20+ and Python 3.10+ are required for development. The installed plugin uses Decky's Python and has no third-party Python dependencies.

```sh
npm ci
npm test
npm run package
npm run verify-package
```

`npm run package` removes previous build output, type-checks the frontend, builds `dist/index.js`, and creates `release/ssh-switch-<version>.zip`, `release/ssh-switch-<version>-source.zip`, and `release/SHA256SUMS`. Each archive has a single `decky-ssh/` directory and includes the bundled Decky API's source and license. The source archive also includes the dependency lockfile, tests, build scripts and GitHub Actions workflow. See `THIRD_PARTY_NOTICES.md` for library details.

Generated ZIPs, `dist/`, `release/`, `node_modules/`, Python caches and local environment files are ignored by Git. Packaging keeps only the current version's two ZIPs and checksums. Run `npm run clean` to remove generated builds, releases and Python caches when finished; installed development dependencies stay in `node_modules/`.

The test suite covers backend controls, real Linux password hashing, and simulated GitHub release publishing. Tests never operate on real services or accounts, and release tests use a local fake GitHub CLI. Linux-only checks are skipped on Windows.


## CI/CD and releases

Publish the contents of this `decky-ssh` directory as the repository root. The workflow is `.github/workflows/build-release.yml`.

- Every branch push and pull request runs the tests, type-checks, builds and verifies both ZIPs. The archives and checksums are available as workflow artifacts for 14 days.
- Pushing a version tag such as `v0.1.4` runs the same checks, then creates a GitHub Release containing the installable ZIP, source ZIP and `SHA256SUMS`. The tag must match `package.json` and `package-lock.json`.
- Tags such as `v0.2.0-beta.1` produce prereleases. The workflow can also be run manually; selecting a version tag enables publishing, while selecting a branch only builds artifacts.

After committing and pushing this project to GitHub, publish the current version with:

```sh
git tag v0.1.4
git push origin v0.1.4
```

For subsequent releases, run `npm version patch` (or `minor` / `major`) in a clean Git checkout, then push the commit and generated tag with `git push origin HEAD --follow-tags`.

The workflow uses GitHub's automatic `GITHUB_TOKEN`; no personal token is needed. Only the release job gets `contents: write`. It uploads assets to a draft before publishing, supports resuming an interrupted draft, and leaves already-published releases intact. Never move a published version tag; bump the version for changed builds.

## Development references

- [Decky plugin template and packaging](https://github.com/SteamDeckHomebrew/decky-plugin-template)
- [Decky plugin runtime and host-account environment](https://github.com/SteamDeckHomebrew/decky-loader/blob/main/backend/decky_loader/plugin/sandboxed_plugin.py)
- [systemctl command semantics](https://www.freedesktop.org/software/systemd/man/latest/systemctl.html)
- [chpasswd documentation](https://github.com/shadow-maint/shadow/blob/master/man/chpasswd.8.xml)
- [Linux password hashing API](https://manpages.debian.org/testing/libcrypt-dev/crypt.3.en.html)
- [GitHub Actions workflow syntax](https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax)
