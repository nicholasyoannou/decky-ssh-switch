import deckyPlugin from "@decky/rollup";
import { readFile } from "node:fs/promises";
import { thirdPartyFiles } from "./scripts/third-party.mjs";

const config = deckyPlugin({});
config.output.sourcemap = false;
config.plugins.push({
  name: "third-party-notices",
  async generateBundle() {
    for (const [fileName, sourcePath] of thirdPartyFiles) {
      this.emitFile({
        type: "asset",
        fileName,
        source: await readFile(new URL(sourcePath, import.meta.url)),
      });
    }
  },
});
export default config;
