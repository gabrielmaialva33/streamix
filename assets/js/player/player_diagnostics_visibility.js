export function bufferDiagnosticsEnabled(environment = window) {
  return environment?.__STREAMIX_DEBUG__ === true;
}
