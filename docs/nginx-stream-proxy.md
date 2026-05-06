# Stream-proxy reverse proxy (nginx)

`docs/nginx-stream-proxy.conf` is the reference template for the egress
edge that fronts every remote provider Streamix talks to (IPTV streams,
TMDB, image proxies). Versioned here so changes go through code review
and the prod server stays a thin substitution layer over this file.

## Why a separate egress

The IPTV provider's WAF rate-limits per-ASN and per-User-Agent. Putting
the egress on a dedicated host:

1. Keeps Streamix BEAM IPs off the provider's blocklist when CI /
   autoscaling churns the app tier.
2. Hosts the slow part of the vauth redirect chain (8-20s on cold
   cache) outside the BEAM, so a Phoenix request doesn't hold a
   connection open for it. The matching client side is
   `lib/streamix/iptv/streaming/redirect_resolver.ex`.

## Placeholders

The template uses double-underscore tokens that get substituted at
deploy time. Pick one of the strategies below.

| Token                     | Meaning                                                      |
|---------------------------|--------------------------------------------------------------|
| `__STREAM_PROXY_HOST__`   | Public hostname for the IPTV stream proxy                    |
| `__TMDB_PROXY_HOST__`     | Public hostname for the TMDB image proxy                     |
| `__LEGACY_IMG_HOST__`     | Public hostname for the legacy image proxy                   |
| `__IMG_PROXY_HOST__`      | Public hostname for the generic image proxy                  |
| `__LEGACY_IMG_UPSTREAM__` | Raw upstream hostname for the legacy image cache (no scheme) |
| `__SHARED_HMAC_SECRET__`  | 64-char hex shared with `StreamToken.sign_url/2` on the BEAM |

### Strategy A — `sed` on deploy

```bash
sed \
  -e "s|__STREAM_PROXY_HOST__|stream.example.com|g" \
  -e "s|__TMDB_PROXY_HOST__|tmdb.example.com|g" \
  -e "s|__LEGACY_IMG_HOST__|legacy-img.example.com|g" \
  -e "s|__IMG_PROXY_HOST__|img.example.com|g" \
  -e "s|__LEGACY_IMG_UPSTREAM__|upstream-images.example.net|g" \
  -e "s|__SHARED_HMAC_SECRET__|$STREAM_PROXY_HMAC_SECRET|g" \
  docs/nginx-stream-proxy.conf \
  | sudo tee /etc/nginx/sites-available/stream-proxy >/dev/null

sudo nginx -t && sudo systemctl reload nginx
```

### Strategy B — Ansible / Terraform template

Treat the file as a Jinja/Go template, swap `__FOO__` for `{{ foo }}`,
let your IaC tool render it.

## Operational checklist

- All four virtual servers listen on the same port (8090). A TLS
  terminator (Cloudflare Tunnel, Caddy, etc.) is responsible for
  hostname → port mapping.
- `nginx -t` must succeed before `systemctl reload`. Backups go in
  `/etc/nginx/backups/`, **not** under `sites-enabled/` — duplicate
  `proxy_cache_path` declarations from a `.bak` sibling will fail
  validation.
- Rotate `__SHARED_HMAC_SECRET__` quarterly. The BEAM reads it from
  `STREAM_PROXY_HMAC_SECRET`; rotate both ends in the same deploy
  window or signed-URL playback will 403 until secrets converge.
- The User-Agent (`XCIPTV-v6.0.0`) must stay in sync with the BEAM
  identifiers in `lib/streamix/iptv/streaming/{vod_proxy,redirect_resolver,xtream_client,stream_proxy,stream_multiplexer}.ex`.
  Casing matters — the provider's WAF treats `xciptv-v6.0.0` and
  `XCIPTV-v6.0.0` as different clients.

## Related modules on the BEAM side

- `Streamix.Iptv.Streaming.RedirectResolver` — walks the vauth chain,
  caches the final URL (60s OK / 3s err), single-flight lock.
- `Streamix.Iptv.Streaming.VodProxy` — pumps bytes through the BEAM
  with a 5MB burst buffer and Range-aware mid-stream retry.
- `Streamix.Iptv.Streaming.FailoverPolicy` — rotates to alternate
  provider URLs when the chain lands on a "service-abuse" landing
  page.
- `StreamixWeb.StreamToken.sign_url/2` — produces the
  `?url=&exp=&sig=` triple consumed by the `access_by_lua_block`
  in this config.
