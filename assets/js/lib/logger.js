/**
 * Logger Wrapper
 *
 * Centralizes logging with environment-aware behavior.
 * Disables verbose logs in production to improve performance.
 */

// Detect environment
const isDev = window.location.hostname === 'localhost' ||
              window.location.hostname === '127.0.0.1' ||
              window.location.hostname.includes('.local') ||
              window.__STREAMIX_DEBUG__ === true;

// Log levels
const LogLevel = {
  DEBUG: 0,
  INFO: 1,
  WARN: 2,
  ERROR: 3,
  NONE: 4,
};

// Current log level (can be changed at runtime)
let currentLevel = isDev ? LogLevel.DEBUG : LogLevel.WARN;

// Error reporter callback (set via setErrorReporter)
let errorReporter = null;

/**
 * Set error reporter callback (typically pushEvent from LiveView hook)
 */
export function setErrorReporter(callback) {
  errorReporter = callback;
}

/**
 * Format log message with prefix
 */
function formatMessage(prefix, args) {
  if (typeof args[0] === 'string') {
    return [`[${prefix}] ${args[0]}`, ...args.slice(1)];
  }
  return [`[${prefix}]`, ...args];
}

/**
 * Logger instance creator
 */
function createLogger(prefix) {
  return {
    debug(...args) {
      if (currentLevel <= LogLevel.DEBUG) {
        console.log(...formatMessage(prefix, args));
      }
    },

    log(...args) {
      if (currentLevel <= LogLevel.DEBUG) {
        console.log(...formatMessage(prefix, args));
      }
    },

    info(...args) {
      if (currentLevel <= LogLevel.INFO) {
        console.info(...formatMessage(prefix, args));
      }
    },

    warn(...args) {
      if (currentLevel <= LogLevel.WARN) {
        console.warn(...formatMessage(prefix, args));
      }
    },

    error(...args) {
      if (currentLevel <= LogLevel.ERROR) {
        console.error(...formatMessage(prefix, args));
      }
    },

    /**
     * Report error to backend (always sends, regardless of log level)
     * @param {string} message - Error message
     * @param {Object} context - Additional context (error object, stack, etc)
     */
    reportError(message, context = {}) {
      // Always log to console
      console.error(...formatMessage(prefix, [message, context]));

      // Send to backend if reporter is configured
      if (errorReporter) {
        try {
          errorReporter("player_error", {
            module: prefix,
            message: typeof message === 'string' ? message : String(message),
            context: {
              ...context,
              error: context.error?.message || context.error,
              stack: context.error?.stack,
            },
            timestamp: Date.now(),
            userAgent: navigator.userAgent,
            url: window.location.href,
          });
        } catch (e) {
          console.warn("[Logger] Failed to report error:", e);
        }
      }
    },

    // Always log regardless of level (for critical info)
    always(...args) {
      console.log(...formatMessage(prefix, args));
    },

    // Group logs (only in dev)
    group(label) {
      if (currentLevel <= LogLevel.DEBUG) {
        console.group(`[${prefix}] ${label}`);
      }
    },

    groupEnd() {
      if (currentLevel <= LogLevel.DEBUG) {
        console.groupEnd();
      }
    },

    // Time tracking (only in dev)
    time(label) {
      if (currentLevel <= LogLevel.DEBUG) {
        console.time(`[${prefix}] ${label}`);
      }
    },

    timeEnd(label) {
      if (currentLevel <= LogLevel.DEBUG) {
        console.timeEnd(`[${prefix}] ${label}`);
      }
    },
  };
}

/**
 * Set global log level
 */
export function setLogLevel(level) {
  if (typeof level === 'string') {
    currentLevel = LogLevel[level.toUpperCase()] ?? LogLevel.WARN;
  } else {
    currentLevel = level;
  }
}

/**
 * Enable debug mode (even in production)
 */
export function enableDebug() {
  window.__STREAMIX_DEBUG__ = true;
  currentLevel = LogLevel.DEBUG;
}

/**
 * Disable all logs
 */
export function disableLogs() {
  currentLevel = LogLevel.NONE;
}

/**
 * Get current environment info
 */
export function getEnvInfo() {
  return {
    isDev,
    currentLevel,
    levelName: Object.keys(LogLevel).find(k => LogLevel[k] === currentLevel),
  };
}

// Pre-created loggers for common modules
export const playerLogger = createLogger('VideoPlayer');
export const streamLogger = createLogger('StreamLoader');
export const avplayerLogger = createLogger('AVPlayer');
export const uiLogger = createLogger('PlayerUI');
export const prefsLogger = createLogger('Preferences');
export const networkLogger = createLogger('Network');

// Export factory for custom loggers
export { createLogger, LogLevel };

export default {
  createLogger,
  setLogLevel,
  setErrorReporter,
  enableDebug,
  disableLogs,
  getEnvInfo,
  LogLevel,
  playerLogger,
  streamLogger,
  avplayerLogger,
  uiLogger,
  prefsLogger,
  networkLogger,
};
