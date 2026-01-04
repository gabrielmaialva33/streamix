import { Plugin } from "vite";

export default (device: string): Plugin => ({
  name: "device-config",
  enforce: "pre",
  // change the config file to point to the correct device
  transform: device
    ? (code, id) => {
        if (!id.endsWith("device/config.ts")) return { code, map: null };
        return {
          code: code.replace("#devices/common", `#devices/${device}`),
          map: null,
        };
      }
    : undefined,
  config: config => {
    config.build = config.build ?? {};
    const path = `${device ?? "common"}`;
    config.build.outDir ??= `dist/${path}`;
    config.base ??= `/${path}/`;
  },
});
