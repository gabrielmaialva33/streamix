# Lightning Starter Template for SolidJS

Part of https://lightningtv.dev/

Check out https://github.com/lightning-tv/solid for additional support.

## Quick Start

```sh
> npx degit lightning-tv/solid-starter-template my-app
> cd my-app
> npm i # or yarn or pnpm
> npm start # or yarn or pnpm
```

Read the Solid Docs: https://lightning-tv.github.io/solid/

## Code Samples

For up to date code and examples check out the full solid demo app:

https://github.com/lightning-tv/solid-demo-app

---

# Building for Different Devices (LG, Tizen, etc.)

This project supports building for different target devices such as **LG** and **Tizen** by setting the `TARGET_DEVICE` environment variable. The Vite build process automatically configures the output and device-specific settings based on this value.

## 📌 Setting the Target Device

You can specify the target device in different ways:

### 1️⃣ **Via Command Line (Recommended)**

For **LG**:

```sh
TARGET_DEVICE=lg vite build
```

````

For **Tizen**:

```sh
TARGET_DEVICE=tizen vite build
```

### 2️⃣ **Using `.env` Files**

Create a `.env` file in the project root and set:

```
VITE_TARGET_DEVICE=lg
```

Then, run:

```sh
vite build
```

For **Tizen**, update `.env`:

```
VITE_TARGET_DEVICE=tizen
```

### 3️⃣ **Using `cross-env` (For Windows)**

If you're using Windows (or need cross-platform compatibility), use `cross-env`:

```sh
npx cross-env TARGET_DEVICE=lg vite build
```

---

## ⚙️ How It Works

- A **Vite plugin** automatically updates the project configuration based on `TARGET_DEVICE`.
- Device-specific configurations are adjusted in `device/config.ts` (e.g., replacing `#devices/common` with `#devices/lg` or `#devices/tizen`).
- The output build is stored in `dist/{device}` (e.g., `dist/lg/` or `dist/tizen/`).
- The `base` path is also updated to `/lg/` or `/tizen/` to match the deployment environment.

---

## 📂 Output Structure

After building, the output directory will look like this:

```
dist/
│── lg/
│   ├── assets/
│   ├── index.html
│   ├── ...
│── tizen/
│   ├── assets/
│   ├── index.html
│   ├── ...
```

Each folder contains the build files for the respective platform.

---

## 🚀 Example: Running Different Builds Locally

To preview different builds, use:

```sh
npx vite preview --outDir dist/lg
```

or

```sh
npx vite preview --outDir dist/tizen
```

This starts a local server serving the build for the selected device.

---

## ❓ Troubleshooting

### 1️⃣ **`process.env.TARGET_DEVICE` is undefined**

- Ensure you are using `VITE_TARGET_DEVICE` if accessing it via `import.meta.env.VITE_TARGET_DEVICE`.
- If using `process.env.TARGET_DEVICE`, ensure it's passed in `vite.config.ts` via `define`:
  ```ts
  define: {
    'process.env.TARGET_DEVICE': JSON.stringify(process.env.TARGET_DEVICE || 'common'),
  }
  ```

## 🛠️ Extending for More Devices

To add support for another device (e.g., **Samsung**), ensure:

- A corresponding directory exists under `#devices/` (e.g., `#devices/samsung`).
- The Vite plugin properly maps `#devices/common` to `#devices/samsung`.
- You build using:
  ```sh
  TARGET_DEVICE=samsung vite build
  ```

````
