# Third-party notices

The frontend bundles parts of `@decky/api` version 1.1.3 by the SteamDeckHomebrew Team, licensed under LGPL-2.1. Its unmodified package source, metadata and license are provided under `dist/third_party/decky-api/` in the plugin and source archives, including builds made by the Decky store. The upstream `src/` folder is named `source/` in this copy because the store builder excludes folders named `src`.

The SSH Switch source is under the MIT license in `LICENSE`. The source release contains the frontend source, dependency lockfile and build scripts needed to rebuild the plugin. With Node.js 20+ and PNPM 9.15.9, run `pnpm install --frozen-lockfile`, make any desired changes (including changes to the installed `@decky/api` library), and run `pnpm run package` to create a replacement frontend and plugin ZIP. No signature or integrity check in this plugin prevents installing a modified build.

React and `@decky/ui` are supplied by Decky at runtime and are not bundled. Build tools and packaging dependencies are not included in the installed runtime.

Upstream library: https://github.com/SteamDeckHomebrew/loader-api
