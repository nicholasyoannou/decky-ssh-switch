# Third-party notices

The frontend bundles parts of `@decky/api` version 1.1.3 by the SteamDeckHomebrew Team, licensed under LGPL-2.1. Its unmodified package source, metadata and license are provided under `third_party/decky-api/` in both release archives.

The SSH Switch source is under the MIT license in `LICENSE`. The source release contains the frontend source, dependency lockfile and build scripts needed to rebuild the plugin. Run `npm ci`, make any desired changes (including changes to the installed `@decky/api` library), and run `npm run package` to create a replacement frontend and plugin ZIP. No signature or integrity check in this plugin prevents installing a modified build.

React and `@decky/ui` are supplied by Decky at runtime and are not bundled. Build tools and packaging dependencies are not included in the installed runtime.

Upstream library: https://github.com/SteamDeckHomebrew/loader-api
