# Xtream domain whitelist identity

`providers.send_x_domain` is an operator-only opt-in for providers whose
account whitelist requires a server-side `X-Domain` header. It defaults to
`false` and is accepted by the administrative provider changeset, never the
owner changeset or sync changeset. It is independent of the delivery flags.

The value defaults to the Endpoint's configured public URL host (`PHX_HOST`
in production). Set `IPTV_X_DOMAIN=stream.example.com` to override it. Use a
hostname only, without scheme, port or path. Invalid overrides suppress the
header. The application wires the endpoint host into the domain policy at
startup; restart after changing environment configuration.

After applying `20261019174838_add_send_x_domain_to_providers`, an operator
can enable a provider through the existing administrative facade:

```elixir
provider = Streamix.Providers.get_provider!(provider_id)
{:ok, _} = Streamix.Providers.update_provider(provider, %{send_x_domain: true})
```

Set the flag to `false` to disable it. Register the same public domain in the
provider account whitelist. No whitelist entries are changed automatically.

The header is recomputed for each HTTP hop using the exact, case-insensitive
hosts from `Provider.url_chain/1` (primary URL and registered alternates).
Subdomains and unrelated CDN/redirector hosts do not inherit it. Requests to
unflagged providers never receive it. This covers API/sync/EPG, connection and
health checks, movie/episode/live probes, resolver/prewarm, VOD transfers and
blocks, live sockets, and HLS playlists/keys/segments/prefetch. Existing SSRF
checks, manual redirects and single-use token handling remain in place.

The policy passed to background fetchers contains only hosts and the public
domain, not provider credentials. Resolver and delivery-probe cache identities
include the policy; an opt-in change does not reuse an earlier cached failure.
Already-running live streams retain the identity with which they were opened.
