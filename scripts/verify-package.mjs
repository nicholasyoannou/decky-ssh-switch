import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFile, readdir } from "node:fs/promises";
import { unzipSync, strFromU8 } from "fflate";

const root = new URL("../", import.meta.url);
const { version } = JSON.parse(await readFile(new URL("package.json", root), "utf8"));
assert.deepEqual((await readdir(new URL("release/", root))).sort(), [
  "SHA256SUMS", `ssh-switch-${version}-source.zip`, `ssh-switch-${version}.zip`,
  "ssh-switch-mount-windows.zip", "ssh-switch-mount-linux.zip", "ssh-switch-mount-macos.zip",
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
    ? ["package-lock.json", "src/index.tsx", ".editorconfig", ".gitignore", ".gitattributes", ".github/workflows/build-release.yml", "scripts/clean.mjs", "scripts/package.mjs", "scripts/release.sh", "scripts/check-version.mjs", "scripts/verify-package.mjs", "tests/test_backend.py", "tests/test_connection.py", "tests/test_mount.py", "tests/test_mount_windows.ps1", "tests/test_release.py"]
    : ["dist/index.js"];
  for (const file of ["main.py", "README.md", "assets/logo.png", "assets/screenshots/ssh-controls.png", "assets/screenshots/password-form.png", "LICENSE", "THIRD_PARTY_NOTICES.md", "mount/mount-windows.ps1", "mount/mount-linux.sh", "mount/mount-macos.sh", "mount/mount-unix.sh", ...required]) {
    assert.deepEqual(Buffer.from(files[`decky-ssh/${file}`]), await readFile(new URL(file, root)), `Stale or missing file: ${file}`);
  }
  assert.ok(files["decky-ssh/third_party/decky-api/LICENSE"]);
  for (const name of ["mount-windows.cmd", "unmount-windows.cmd"]) {
    const launcher = Buffer.from(files[`decky-ssh/mount/${name}`]);
    const expectedLauncher = (await readFile(new URL(`mount/${name}`, root), "utf8")).replace(/\r?\n/g, "\r\n");
    assert.equal(launcher.toString("utf8"), expectedLauncher, `${name} is missing, stale or has incorrect line endings.`);
  }
  console.log(`Verified ${filename}: ${Object.keys(files).length} files`);
}

for (const platform of ["windows", "linux", "macos"]) {
  const filename = `ssh-switch-mount-${platform}.zip`;
  const bytes = await readFile(new URL(`release/${filename}`, root));
  const digest = createHash("sha256").update(bytes).digest("hex");
  assert.ok(checksums.split("\n").includes(`${digest}  ${filename}`), `Checksum mismatch: ${filename}`);
  const files = unzipSync(bytes);
  const scripts = platform === "windows"
    ? ["mount-windows.cmd", "unmount-windows.cmd", "mount-windows.ps1"]
    : [`mount-${platform}.sh`, "mount-unix.sh"];
  assert.deepEqual(Object.keys(files).sort(), ["LICENSE", "README.txt", ...scripts].sort(), `Unexpected files in ${filename}`);
  for (const script of scripts) {
    let expected = await readFile(new URL(`mount/${script}`, root));
    if (script.endsWith(".cmd")) expected = Buffer.from(expected.toString("utf8").replace(/\r?\n/g, "\r\n"));
    assert.deepEqual(Buffer.from(files[script]), expected, `Stale or missing file in ${filename}: ${script}`);
    if (script.endsWith(".sh")) assert.ok(!files[script].includes(13), `Shell script must use LF: ${script}`);
  }
  assert.deepEqual(Buffer.from(files.LICENSE), await readFile(new URL("LICENSE", root)));
  const readme = strFromU8(files["README.txt"]);
  assert.ok(readme.includes(`Version: ${version}\n`), `Missing version in ${filename}`);
  assert.ok(readme.includes(scripts[0]), `Missing launch instructions in ${filename}`);
  if (platform === "windows") assert.ok(readme.includes("unmount-windows.cmd"), "Missing unmount instructions.");
  console.log(`Verified ${filename}: ${Object.keys(files).length} files, ${bytes.length} bytes`);
}
