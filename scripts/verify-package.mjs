import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFile, readdir } from "node:fs/promises";
import { unzipSync, strFromU8 } from "fflate";

const root = new URL("../", import.meta.url);
const { version } = JSON.parse(await readFile(new URL("package.json", root), "utf8"));
assert.deepEqual((await readdir(new URL("release/", root))).sort(), [
  "SHA256SUMS", `ssh-switch-${version}-source.zip`, `ssh-switch-${version}.zip`,
].sort(), "The release directory contains stale or unexpected files. Run npm run package.");
const checksums = await readFile(new URL("release/SHA256SUMS", root), "utf8");
for (const source of [false, true]) {
  const filename = `ssh-switch-${version}${source ? "-source" : ""}.zip`;
  const bytes = await readFile(new URL(`release/${filename}`, root));
  const digest = createHash("sha256").update(bytes).digest("hex");
  assert.ok(checksums.split("\n").includes(`${digest}  ${filename}`), `Checksum mismatch: ${filename}`);
  const files = unzipSync(bytes);
  for (const name of Object.keys(files)) {
    assert.ok(name.startsWith("decky-ssh/") && !name.split("/").includes(".."));
    assert.ok(!/(^|\/)(node_modules|\.git|__pycache__)(\/|$)/.test(name));
  }
  const metadata = JSON.parse(strFromU8(files["decky-ssh/package.json"]));
  assert.equal(metadata.version, version);
  const plugin = JSON.parse(strFromU8(files["decky-ssh/plugin.json"]));
  assert.equal(plugin.api_version, 1);
  assert.deepEqual(plugin.flags, ["root"]);
  const required = source
    ? ["package-lock.json", "src/index.tsx", ".editorconfig", ".gitignore", ".gitattributes", ".github/workflows/build-release.yml", "scripts/clean.mjs", "scripts/package.mjs", "scripts/release.sh", "scripts/check-version.mjs", "scripts/verify-package.mjs", "tests/test_backend.py", "tests/test_release.py"]
    : ["dist/index.js"];
  for (const file of ["main.py", "README.md", "assets/logo.png", "assets/screenshots/ssh-controls.png", "assets/screenshots/password-form.png", "LICENSE", "THIRD_PARTY_NOTICES.md", ...required]) {
    assert.deepEqual(Buffer.from(files[`decky-ssh/${file}`]), await readFile(new URL(file, root)), `Stale or missing file: ${file}`);
  }
  assert.ok(files["decky-ssh/third_party/decky-api/LICENSE"]);
  console.log(`Verified ${filename}: ${Object.keys(files).length} files`);
}
