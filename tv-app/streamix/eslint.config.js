import globals from "globals";
import pluginJs from "@eslint/js";
import tseslint from "typescript-eslint";

export default [
  {
    files: ["**/*.{js,mjs,cjs,ts,jsx,tsx}"],
  },
  {
    languageOptions: { globals: globals.browser },
  },
  pluginJs.configs.recommended,
  ...tseslint.configs.recommended,
  {
    env: {
      node: true,
      commonjs: true,
    },
    rules: {
      "@typescript-eslint/no-unused-vars": [
        "error",
        { vars: "local", args: "after-used", varsIgnorePattern: "(^_|Ref$)", argsIgnorePattern: "^_" },
      ],
      "comma-dangle": ["error", "always-multiline"],
      "no-process-env": "off", // disallow use of process.env
      quotes: ["error", "double", { avoidEscape: true }],
      semi: ["error", "always"],
      "no-unused-vars": [
        "warn",
        {
          argsIgnorePattern: "^_",
          varsIgnorePattern: "^_",
        },
      ],
      "@typescript-eslint/no-explicit-any": "off",
      "func-call-spacing": ["error", "never"],
    },
  },
];
