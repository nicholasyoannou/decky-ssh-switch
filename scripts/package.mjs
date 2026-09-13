import { readFile, mkdir, writeFile } from "node:fs/promises";
import { createHash } from "node:crypto";
import { zipSync } from "fflate";

const root = new URL("../", import.meta.url);
const metadata = JSON.parse(await readFile(new URL("package.json", root), "utf8"));
// Explicit allowlists keep neighbouring backups, credentials and node_modules out.
const documentationFiles = ["README.md", "assets/logo.png", "assets/screenshots/ssh-controls.png", "assets/screenshots/password-form.png"];
const mountFiles = ["mount/mount-windows.ps1", "mount/mount-linux.sh", "mount/mount-macos.sh", "mount/mount-unix.sh"];
const runtimeFiles = ["plugin.json", "package.json", "main.py", "dist/index.js", ...documentationFiles, ...mountFiles, "LICENSE", "THIRD_PARTY_NOTICES.md"];
const sourceFiles = ["plugin.json", "package.json", "package-lock.json", "main.py", ...documentationFiles, ...mountFiles, "LICENSE", "THIRD_PARTY_NOTICES.md", ".gitignore", ".gitattributes", ".editorconfig", ".github/workflows/build-release.yml", "rollup.config.js", "tsconfig.json", "src/index.tsx", "tests/test_backend.py", "tests/test_connection.py", "tests/test_mount.py", "tests/test_mount_windows.ps1", "tests/test_release.py", "scripts/package.mjs", "scripts/clean.mjs", "scripts/check-version.mjs", "scripts/verify-package.mjs", "scripts/release.sh"];
const apiFiles = ["LICENSE", "README.md", "package.json", "src/index.ts", "src/types.ts", "src/types.d.ts", "dist/index.js", "dist/index.d.ts", "dist/types.d.ts"];

async function archive(files) {
  const entries = {};
  const add = async (destination, file) => {
    entries[`decky-ssh/${destination}`] = [new Uint8Array(await readFile(new URL(file, root))), { os: 3, attrs: 0o100644 << 16 }];
  };
  for (const file of files) await add(file, file);
  for (const file of apiFiles) await add(`third_party/decky-api/${file}`, `node_modules/@decky/api/${file}`);
  return zipSync(entries, { level: 9 });
}

await mkdir(new URL("release/", root), { recursive: true });
const name = `ssh-switch-${metadata.version}.zip`;
await writeFile(new URL(`release/${name}`, root), await archive(runtimeFiles));
console.log(`Created release/${name}`);
const sourceName = `ssh-switch-${metadata.version}-source.zip`;
await writeFile(new URL(`release/${sourceName}`, root), await archive(sourceFiles));
console.log(`Created release/${sourceName}`);
const checksums = [];
for (const file of [name, sourceName]) {
  const digest = createHash("sha256").update(await readFile(new URL(`release/${file}`, root))).digest("hex");
  checksums.push(`${digest}  ${file}`);
}
await writeFile(new URL("release/SHA256SUMS", root), checksums.join("\n") + "\n");
