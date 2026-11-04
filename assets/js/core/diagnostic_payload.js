const REDACTED = "[redacted]";
const REDACTED_URL = "[redacted-url]";
const TRUNCATED = "[truncated]";
const CIRCULAR = "[circular]";
const MAX_DEPTH = 4;
const MAX_ARRAY_LENGTH = 25;
const MAX_STRING_LENGTH = 500;
const URL_PATTERN = /\b(?:https?|wss?):\/\/[^\s"'<>]+/giu;
const SENSITIVE_SUFFIXES = [
  "api_key",
  "authorization",
  "cookie",
  "credential",
  "password",
  "secret",
  "token",
  "uri",
  "url",
];

function isSensitiveKey(key) {
  const normalized = String(key ?? "")
    .replace(/([a-z0-9])([A-Z])/g, "$1_$2")
    .toLowerCase();

  return SENSITIVE_SUFFIXES.some(
    (suffix) => normalized === suffix || normalized.endsWith(`_${suffix}`),
  );
}

function sanitizeString(value) {
  const redacted = value.replace(URL_PATTERN, REDACTED_URL);

  if (redacted.length <= MAX_STRING_LENGTH) return redacted;
  return `${redacted.slice(0, MAX_STRING_LENGTH)}…`;
}

function sanitizeValue(value, key, depth, seen) {
  if (value === null || value === undefined) return value;
  if (isSensitiveKey(key)) return REDACTED;

  if (typeof value === "string") return sanitizeString(value);
  if (typeof value === "number" || typeof value === "boolean") return value;
  if (typeof value === "bigint") return value.toString();
  if (typeof value === "function" || typeof value === "symbol") return undefined;

  if (value instanceof Error) {
    return {
      name: sanitizeString(value.name || "Error"),
      message: sanitizeString(value.message || ""),
    };
  }

  if (value instanceof Date) return value.toISOString();
  if (depth >= MAX_DEPTH) return TRUNCATED;
  if (seen.has(value)) return CIRCULAR;

  seen.add(value);

  if (Array.isArray(value)) {
    const sanitized = value
      .slice(0, MAX_ARRAY_LENGTH)
      .map((entry) => sanitizeValue(entry, "", depth + 1, seen));
    seen.delete(value);
    return sanitized;
  }

  const sanitized = {};
  for (const [entryKey, entryValue] of Object.entries(value)) {
    const normalized = sanitizeValue(entryValue, entryKey, depth + 1, seen);
    if (normalized !== undefined) sanitized[entryKey] = normalized;
  }

  seen.delete(value);
  return sanitized;
}

export function sanitizeDiagnosticPayload(payload) {
  if (!payload || typeof payload !== "object") return {};
  return sanitizeValue(payload, "", 0, new WeakSet());
}
