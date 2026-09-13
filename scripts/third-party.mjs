// These assets live under dist/ so Decky's store packager includes them.
const apiFiles = ["LICENSE", "README.md", "package.json", "src/index.ts", "src/types.ts", "src/types.d.ts", "dist/index.js", "dist/index.d.ts", "dist/types.d.ts"];

export const thirdPartyFiles = [
  ["THIRD_PARTY_NOTICES.md", "THIRD_PARTY_NOTICES.md"],
  // The store builder also excludes directories named src at any depth.
  ...apiFiles.map((file) => [`third_party/decky-api/${file.replace(/^src\//, "source/")}`, `node_modules/@decky/api/${file}`]),
];
