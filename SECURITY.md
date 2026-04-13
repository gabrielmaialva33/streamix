# Security Policy

## Supported Versions

Streamix does not currently maintain multiple supported release branches. Security fixes land on the current `master`
branch and in the latest published container image.

| Version / branch | Supported |
| --- | --- |
| `master` / current `HEAD` | Yes |
| `ghcr.io/gabrielmaialva33/streamix:latest` | Yes |
| Historical tags (`v1.0.0` through `v1.5.0`) | No backports |

## Reporting a Vulnerability

Do **not** open a public GitHub issue for a suspected vulnerability.

Instead, report it privately to:

- Email: **gabrielmaialva33@gmail.com**

If you need encrypted communication, mention that in the first email and a secure channel can be arranged.

## What to Include

Please include:

1. Vulnerability type
2. Affected area or file path
3. Exact reproduction steps
4. Impact and attacker prerequisites
5. Suggested mitigation, if you have one
6. Proof of concept or logs, if safe to share

Helpful examples of affected surfaces in this repo:

- browser auth and session handling
- `/api/v1/*` endpoints
- `StreamixWeb.StreamToken` and stream proxy flows
- provider credential storage and encryption
- RabbitMQ / Redis / Qdrant / GIndex integration boundaries
- CSP, CORS, and rate-limiting behavior

## Response Expectations

Current response targets are best effort:

| Stage | Target |
| --- | --- |
| Acknowledgement | within 72 hours |
| Initial triage | within 7 days |
| Follow-up status updates | weekly while active |
| Fix timeline | depends on severity and reproducibility |

We will do our best to:

- confirm receipt
- reproduce and triage the issue
- communicate impact and planned remediation
- coordinate disclosure after a fix ships

## Scope

### In scope

- Streamix application code in this repository
- Web UI, LiveView routes, and API routes
- Authentication and authorization flows
- Signed stream-token and proxy behavior
- Secrets handling, credential storage, and encryption
- Default Docker / runtime configuration shipped in the repo

### Out of scope

- Vulnerabilities in third-party dependencies themselves
- Misconfiguration in a downstream deployment you do not control
- Social engineering, phishing, or credential stuffing
- Denial-of-service reports without a concrete product bug
- Issues in the extracted TV app repository

## Security Notes for Deployers

Before deploying Streamix:

- set `SECRET_KEY_BASE` and `LIVE_VIEW_SIGNING_SALT`
- set `PROVIDER_ENCRYPTION_KEY`
- keep `.env` and runtime secrets out of git
- serve the app behind HTTPS
- restrict `CORS_ORIGINS`
- configure `API_KEYS` for external clients
- rotate provider credentials and API keys if exposure is suspected
- keep Redis, RabbitMQ, PostgreSQL, and Qdrant off the public internet unless intentionally secured

Sensitive environment variables commonly involved in reports include:

- `SECRET_KEY_BASE`
- `LIVE_VIEW_SIGNING_SALT`
- `PROVIDER_ENCRYPTION_KEY`
- `DATABASE_URL`
- `REDIS_URL`
- `GLOBAL_PROVIDER_PASSWORD`
- `GEMINI_API_KEY`
- `NVIDIA_API_KEY`
- `QDRANT_API_KEY`
- `API_KEYS`

Thanks for helping keep Streamix secure.
