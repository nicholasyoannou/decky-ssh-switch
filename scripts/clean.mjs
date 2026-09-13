import { lstat, realpath, rm } from "node:fs/promises";
import { dirname, isAbsolute, relative, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";

const root = await realpath(fileURLToPath(new URL("../", import.meta.url)));
const generated = ["dist", "release", "__pycache__", "tests/__pycache__"];
const targets = [];

// Validate every destination before deleting anything. Never follow a link
// outside the project or accept a user-provided cleanup path.
for (const name of generated) {
  const target = resolve(root, name);
  try {
    const stat = await lstat(target);
    const resolved = await realpath(target);
    const within = relative(root, resolved);
    if (stat.isSymbolicLink() || !within || within === ".." || within.startsWith(`..${sep}`) || isAbsolute(within)) {
      throw new Error(`Refusing to clean a linked or external path: ${name}`);
    }
    if (await realpath(dirname(target)) !== dirname(target)) {
      throw new Error(`Refusing to clean through a linked directory: ${name}`);
    }
    targets.push(target);
  } catch (error) {
    if (error.code !== "ENOENT") throw error;
  }
}

for (const target of targets) await rm(target, { recursive: true, force: true });
console.log("Removed generated builds, release archives and Python caches.");
