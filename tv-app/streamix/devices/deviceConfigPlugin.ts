import { Plugin } from "vite";
import path from "path";

export default (device: string): Plugin => ({
  name: "device-config",
  enforce: "pre",
  // Resolve #devices/common to the correct device folder
  resolveId(id) {
    if (device && id === "#devices/common") {
      return { id: `#devices/${device}`, external: false };
    }
    return null;
  },
  config: config => {
    config.build = config.build ?? {};
    const devicePath = `${device ?? "common"}`;
    config.build.outDir ??= `dist/${devicePath}`;
    // Use relative paths for embedded devices (tizen, lg), absolute for browser (common)
    const isEmbedded = device === "tizen" || device === "lg";
    config.base ??= isEmbedded ? "./" : `/${devicePath}/`;
  },
});
