import { appendFileSync, readFileSync } from "node:fs";

const root = new URL("../", import.meta.url);
const { version } = JSON.parse(readFileSync(new URL("package.json", root), "utf8"));
const lock = JSON.parse(readFileSync(new URL("package-lock.json", root), "utf8"));
if (!/^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$/.test(version)) {
  throw new Error("package.json must contain a version such as 0.1.1 or 0.2.0-beta.1.");
}
if (lock.version !== version || lock.packages[""].version !== version) {
  throw new Error("package.json and package-lock.json versions must match. Use npm version to update both.");
}
if (process.env.GITHUB_REF_TYPE === "tag" && process.env.GITHUB_REF_NAME !== `v${version}`) {
  throw new Error(`Release tag must be v${version} to match package.json.`);
}
if (process.env.GITHUB_OUTPUT) appendFileSync(process.env.GITHUB_OUTPUT, `version=${version}\n`);
console.log(`Version verified: ${version}`);
