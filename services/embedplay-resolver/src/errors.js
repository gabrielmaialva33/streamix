export const statusCodes = {
  invalid_request: 400, unauthorized: 401, not_found: 404, busy: 503,
  resolution_timeout: 504, stream_unavailable: 502, challenge_required: 502,
  resolver_unavailable: 503,
};

export class ResolverError extends Error {
  constructor(code) {
    super(code);
    this.code = code;
  }
}

export function safeCode(error) {
  return error instanceof ResolverError && Object.hasOwn(statusCodes, error.code)
    ? error.code : 'resolver_unavailable';
}

export function normalizeInput(input) {
  if (!input || typeof input !== 'object' || Array.isArray(input) ||
      Object.keys(input).some(key => !['tmdb_id', 'imdb_id', 'audio'].includes(key))) {
    throw new ResolverError('invalid_request');
  }
  const tmdb = input.tmdb_id == null ? null : String(input.tmdb_id);
  const imdb = input.imdb_id ?? null;
  if ((tmdb !== null && (!/^[1-9]\d{0,9}$/.test(tmdb) || !Number.isSafeInteger(Number(tmdb)))) ||
      (imdb !== null && (typeof imdb !== 'string' || !/^tt\d{5,12}$/.test(imdb))) ||
      (!tmdb && !imdb) || !['dubbed', 'subtitled'].includes(input.audio)) {
    throw new ResolverError('invalid_request');
  }
  return { tmdb_id: tmdb, imdb_id: imdb, audio: input.audio };
}
