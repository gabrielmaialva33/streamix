# Streamix Catalog API v1

The catalog API is the mobile/TV integration boundary for public provider discovery, canonical media cards, details,
and signed playback URLs. Its executable OpenAPI 3 contract is served by the application:

- `GET /api/v1/openapi.json` — machine-readable contract
- `GET /api/v1/docs` — interactive Swagger UI

The OpenAPI document currently covers all 19 routes owned by `CatalogController`. Other `/api/v1` resource families
keep their existing controller contracts until they are added to the executable specification.

## Authentication

Send the configured integration key only in the request header:

```http
X-API-Key: your-integration-key
```

Query-string API keys are not accepted. Provider credentials, upstream URLs, and final upstream playback URLs are never
part of catalog responses.

## Response envelopes

Every successful catalog response has a top-level `data` field. Resource metadata is kept under `meta` so clients do
not need endpoint-specific rules for totals and pagination.

```json
{
  "data": [
    {
      "id": 42,
      "name": "Example Movie",
      "provider": {"id": 3, "name": "Primary", "type": "xtream"}
    }
  ],
  "meta": {
    "pagination": {
      "limit": 20,
      "offset": 0,
      "total": 81,
      "has_more": true,
      "next_offset": 20
    },
    "filters": {
      "provider_id": null,
      "provider_type": null,
      "category_id": null,
      "search": null,
      "sort": null
    }
  }
}
```

Failures retain one stable envelope:

```json
{
  "error": {
    "code": "invalid_provider_type",
    "message": "Provider type must be xtream, gindex, or torrent"
  }
}
```

Treat `error.code` as the programmatic contract. The human-readable message may improve without a version bump.

Path and query parameters are cast and validated against the executable OpenAPI document before controller code runs.
Malformed values, out-of-range pagination, and unsupported enums return `400`; a well-formed identifier that is not
present returns `404`.

## Providers and filters

`GET /api/v1/catalog/providers` lists only active providers whose visibility is `global` or `public`. Each entry exposes
an identifier, display name, adapter type, supported content types, and synchronized row counts. It intentionally omits
credentials and connection endpoints.

Movies, series, channels, categories, featured, home, curated shelves, catalog search, and suggestions accept:

| Parameter       | Meaning                                                           |
|-----------------|-------------------------------------------------------------------|
| `provider_id`   | Exact public provider identifier returned by `/catalog/providers` |
| `provider_type` | Adapter filter: `xtream`, `gindex`, or `torrent`                  |

Movie and series listings aggregate every eligible provider by default. Equivalent variants are collapsed into one
canonical card before `offset` and `limit` are applied, so `meta.pagination.total` describes the canonical result set.
Ranked movie and series search results use the same canonicalization after relevance scoring, preventing provider
variants from crowding distinct matches out of a result bucket. Pass a provider filter when a client needs to browse or
search one source explicitly. Applied filters are echoed in `meta.filters`.

Categories remain provider-scoped: category IDs from different providers are never assumed to be interchangeable. Live
channels are available only from Xtream-compatible providers, even though the shared `provider_type` filter uses the
same contract.

## Pagination and ordering

Catalog pages use offset pagination:

- `limit`: `1..100`
- `offset`: `0..100000`
- `next_offset`: the next usable offset or `null` on the final page

Movie and series ordering supports `rating_desc`, `created_desc`, `year_desc`, and `name_asc`. Stable identifier
tie-breakers prevent duplicates from moving between adjacent pages when their visible sort fields are equal.

## Compatibility note

This pre-release establishes the documented catalog v1 envelope and intentionally replaces the older resource-specific
success keys such as `movies`, `series`, `channels`, `items`, `featured`, and top-level `total`.

Client migration is mechanical:

| Previous read                                            | Current read                       |
|----------------------------------------------------------|------------------------------------|
| `payload.movies` / `payload.series` / `payload.channels` | `payload.data`                     |
| `payload.items`                                          | `payload.data`                     |
| `payload.featured`                                       | `payload.data`                     |
| `payload.total`                                          | `payload.meta.pagination.total`    |
| `payload.has_more`                                       | `payload.meta.pagination.has_more` |
| `payload.type` on shelves                                | `payload.meta.type`                |

Generate clients from `/api/v1/openapi.json` or validate hand-written clients against that document instead of copying
response maps from examples.

## Development validation

Response contract tests run with the normal ExUnit suite. To also lint the serialized OpenAPI document against
Redocly's recommended rules:

```bash
mix openapi.spec.json --spec StreamixWeb.Api.V1.OpenApi --start-app=false --vendor-extensions=false /tmp/streamix-openapi.json
npm --prefix assets run lint:openapi -- /tmp/streamix-openapi.json
```

The Chromium CI job runs the same commands before browser journeys.
