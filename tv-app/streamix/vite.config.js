import { defineConfig } from "vite";
import solidPlugin from "vite-plugin-solid";
import hexColorTransform from "@lightningtv/vite-hex-transform";
import legacy from "@vitejs/plugin-legacy";
import path from "path";
import deviceConfigPlugin from "./devices/deviceConfigPlugin.js";

const envDir = "./environments";

export default defineConfig(({ mode }) => {
  // Get environment variables
  // const env = loadEnv(mode, path.join(__dirname, envDir));

  return {
    envDir,
    define: {
      __DEV__: mode !== "production",
    },
    plugins: [
      deviceConfigPlugin(process.env.TARGET_DEVICE),
      hexColorTransform({
        include: ["src/**/*.{ts,tsx,js,jsx}"],
      }),
      solidPlugin({
        solid: {
          moduleName: "@lightningtv/solid",
          generate: "universal",
        },
      }),
      legacy({
        targets: ["defaults", "Chrome >= 49"],
        // For Tizen: disable modern chunks since file:// protocol causes both to run
        renderModernChunks: process.env.TARGET_DEVICE !== "tizen",
        modernPolyfills: process.env.TARGET_DEVICE === "tizen" ? false : [
          // Safari 11 has modules, but throws > ReferenceError: Can't find variable: globalThis
          "es.global-this",
        ],
      }),
    ],
    resolve: {
      alias: {
        theme: path.resolve(__dirname, "./theme.js"),
        "@": path.resolve(__dirname, "./src"),
        "#devices": path.resolve(__dirname, "./devices"),
      },
      dedupe: ["solid-js", "@lightningtv/solid", "@lightningtv/core", "@lightningjs/renderer"],
    },
    optimizeDeps: {
      exclude: ["@lightningtv/solid", "@lightningtv/core", "@lightningjs/renderer"],
    },
    server: {
      hmr: true,
      // Removed COEP/COOP headers that were blocking cross-origin fetch
    },
    test: {
      browser: {
        enabled: true,
        headless: false,
        provider: "playwright",
        name: "webkit",
      },
      testTransformMode: { web: ["/.[jt]sx?$/"] },
      globals: true,
    },
  };
});
