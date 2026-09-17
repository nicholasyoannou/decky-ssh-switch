import { readFile, mkdir, writeFile } from "node:fs/promises";
import { createHash } from "node:crypto";
import { zipSync } from "fflate";
import { thirdPartyFiles } from "./third-party.mjs";

const root = new URL("../", import.meta.url);
const metadata = JSON.parse(await readFile(new URL("package.json", root), "utf8"));
// Explicit allowlists keep neighbouring backups, credentials and node_modules out.
const documentationFiles = ["README.md", "assets/logo.png", "assets/screenshots/ssh-controls.png", "assets/screenshots/password-form.png"];
const mountFiles = ["mount/mount-windows.cmd", "mount/unmount-windows.cmd", "mount/mount-windows.ps1", "mount/mount-linux.sh", "mount/unmount-linux.sh", "mount/mount-macos.sh", "mount/unmount-macos.sh", "mount/mount-unix.sh"];
const runtimeFiles = ["plugin.json", "package.json", "main.py", "dist/index.js", ...documentationFiles, ...mountFiles, "LICENSE", "THIRD_PARTY_NOTICES.md"];
const sourceFiles = ["plugin.json", "package.json", "pnpm-lock.yaml", "main.py", ...documentationFiles, ...mountFiles, "LICENSE", "THIRD_PARTY_NOTICES.md", ".gitignore", ".gitattributes", ".editorconfig", ".github/workflows/build-release.yml", "rollup.config.js", "tsconfig.json", "src/index.tsx", "src/qr.ts", "tests/test_backend.py", "tests/test_connection.py", "tests/test_mount.py", "tests/test_mount_windows.ps1", "tests/test_release.py", "scripts/package.mjs", "scripts/clean.mjs", "scripts/check-version.mjs", "scripts/verify-package.mjs", "scripts/third-party.mjs", "scripts/release.sh"];

async function addFile(entries, destination, file) {
  let bytes = await readFile(new URL(file, root));
  // Build on Linux, but keep the double-click Windows launcher in CRLF form.
  if (destination.endsWith(".cmd")) bytes = Buffer.from(bytes.toString("utf8").replace(/\r?\n/g, "\r\n"));
  const mode = destination.endsWith(".sh") ? 0o100755 : 0o100644;
  entries[destination] = [new Uint8Array(bytes), { os: 3, attrs: mode << 16 }];
}

async function archive(files) {
  const entries = {};
  for (const file of files) await addFile(entries, `decky-ssh/${file}`, file);
  for (const [file] of thirdPartyFiles) await addFile(entries, `decky-ssh/dist/${file}`, `dist/${file}`);
  return zipSync(entries, { level: 9 });
}

async function mountArchive(platform) {
  const entries = {};
  const files = platform === "windows"
    ? ["mount-windows.cmd", "unmount-windows.cmd", "mount-windows.ps1"]
    : [`mount-${platform}.sh`, `unmount-${platform}.sh`, "mount-unix.sh"];
  for (const file of files) await addFile(entries, file, `mount/${file}`);
  await addFile(entries, "LICENSE", "LICENSE");
  const instructions = {
    windows: "Double-click mount-windows.cmd to mount, or unmount-windows.cmd to disconnect.\nKeep both launchers beside mount-windows.ps1.\nMissing SSHFS-Win and WinFsp dependencies are installed automatically when mounting.\n\nMount locations are recorded even if you choose not to save your password.\nUnmounting keeps saved settings for the next connection. To change them, run:\nmount-windows.cmd -Configure\n",
    linux: "Install sshfs with your package manager (Ubuntu/Debian: sudo apt install sshfs).\nIn this extracted folder, run as your normal user:\nbash mount-linux.sh\n\nTo disconnect the recorded mounts:\nbash unmount-linux.sh\n",
    macos: "Install FUSE-T and SSHFS with Homebrew:\nbrew install macos-fuse-t/homebrew-cask/fuse-t macos-fuse-t/homebrew-cask/sshfs-fuse-t\n\nIn this extracted folder, run as your normal user:\nbash mount-macos.sh\n\nTo disconnect the recorded mounts:\nbash unmount-macos.sh\n",
  };
  const readme = `SSH Switch mounting helper - ${platform}\nVersion: ${metadata.version}\n\nExtract all files before running.\nEnable SSH on your Deck and open SSH Switch > Connect from computer.\nKeep both devices on the same network.\n\n${instructions[platform]}\nHelp: https://github.com/nicholasyoannou/decky-ssh-switch#mount-files-on-your-computer\n`;
  entries["README.txt"] = [new TextEncoder().encode(readme), { os: 3, attrs: 0o100644 << 16 }];
  return zipSync(entries, { level: 9 });
}

await mkdir(new URL("release/", root), { recursive: true });
const name = `ssh-switch-${metadata.version}.zip`;
await writeFile(new URL(`release/${name}`, root), await archive(runtimeFiles));
console.log(`Created release/${name}`);
const sourceName = `ssh-switch-${metadata.version}-source.zip`;
await writeFile(new URL(`release/${sourceName}`, root), await archive(sourceFiles));
console.log(`Created release/${sourceName}`);
const releaseFiles = [name, sourceName];
for (const platform of ["windows", "linux", "macos"]) {
  // Stable asset names let README links follow GitHub's latest release.
  const filename = `ssh-switch-mount-${platform}.zip`;
  await writeFile(new URL(`release/${filename}`, root), await mountArchive(platform));
  releaseFiles.push(filename);
  console.log(`Created release/${filename}`);
}
const checksums = [];
for (const file of releaseFiles) {
  const digest = createHash("sha256").update(await readFile(new URL(`release/${file}`, root))).digest("hex");
  checksums.push(`${digest}  ${file}`);
}
await writeFile(new URL("release/SHA256SUMS", root), checksums.join("\n") + "\n");
