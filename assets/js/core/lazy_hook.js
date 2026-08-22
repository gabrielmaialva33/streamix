const LIFECYCLE_METHODS = new Set([
  "mounted",
  "beforeUpdate",
  "updated",
  "destroyed",
  "disconnected",
  "reconnected",
]);

function installCustomMethods(context, implementation) {
  for (const [name, value] of Object.entries(implementation)) {
    if (!LIFECYCLE_METHODS.has(name)) {
      context[name] = value;
    }
  }
}

/**
 * Keeps route-specific LiveView hooks out of the application entry bundle.
 *
 * LiveView creates the hook context synchronously, so the lightweight proxy
 * stays registered up front and hydrates the real implementation only when an
 * element using that hook actually mounts.
 */
export function createLazyHook(name, loader, { shouldLoad = () => true } = {}) {
  const stateKey = Symbol(`streamix:${name}`);
  let modulePromise;

  const load = () => {
    modulePromise ||= loader().catch((error) => {
      modulePromise = null;
      throw error;
    });

    return modulePromise;
  };

  return {
    async mounted() {
      const state = {
        destroyed: false,
        implementation: null,
        mounted: false,
        pendingUpdated: false,
      };
      this[stateKey] = state;

      try {
        if (shouldLoad(this) === false) {
          state.skipped = true;
          return;
        }

        const module = await load();
        if (state.destroyed) return;

        const implementation = module.default;
        if (!implementation || typeof implementation !== "object") {
          throw new TypeError(`${name} lazy hook must have a default object export`);
        }

        installCustomMethods(this, implementation);
        state.implementation = implementation;
        implementation.mounted?.call(this);
        state.mounted = true;

        if (state.pendingUpdated) {
          implementation.updated?.call(this);
          state.pendingUpdated = false;
        }
      } catch (error) {
        if (state.destroyed) return;
        this.el.dataset.lazyHookError = name;

        if (globalThis.__streamixLazyHookDiagnostics === true) {
          const errorName = error?.name || "Error";
          const errorMessage = error?.message || String(error);
          const detail = `${errorName}: ${errorMessage}`.slice(0, 300);
          this.el.dataset.lazyHookErrorDetail = detail;
          globalThis.__streamixLazyHookErrors ||= {};
          globalThis.__streamixLazyHookErrors[name] = detail;
        }

        console.error(`[Streamix] Failed to load ${name} hook`, error);
      }
    },

    beforeUpdate() {
      const state = this[stateKey];
      if (state?.mounted) {
        state.implementation.beforeUpdate?.call(this);
      }
    },

    updated() {
      const state = this[stateKey];
      if (!state || state.destroyed) return;

      if (state.mounted) {
        state.implementation.updated?.call(this);
      } else {
        state.pendingUpdated = true;
      }
    },

    destroyed() {
      const state = this[stateKey];
      if (!state) return;

      state.destroyed = true;
      if (state.mounted) {
        state.implementation.destroyed?.call(this);
      }
    },

    disconnected() {
      const state = this[stateKey];
      if (state?.mounted && !state.destroyed) {
        state.implementation.disconnected?.call(this);
      }
    },

    reconnected() {
      const state = this[stateKey];
      if (state?.mounted && !state.destroyed) {
        state.implementation.reconnected?.call(this);
      }
    },
  };
}
