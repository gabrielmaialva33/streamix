# Jogos de hoje

The optional Xtream sports feed populates a rail on `/browse` and scoped
provider channel pages, plus `GET /api/v1/catalog/games` for TV clients.
No new player or direct upstream playback path is introduced: a card opens
`/watch/live_channel/:id`, with the existing authorization and HLS gateway.

## Operator setup

Apply `20261019182926_add_provider_games.exs`, then enable the administrative
`games_enabled` flag for the desired Xtream provider. Owner and sync
changesets cannot set this flag. It defaults to false.

```elixir
provider = Streamix.Providers.get_provider!(provider_id)
{:ok, _} = Streamix.Providers.update_provider(provider, %{games_enabled: true})
Streamix.Workers.SyncGamesWorker.new(%{provider_id: provider_id}) |> Oban.insert()
```

For accounts requiring domain whitelisting, also enable `send_x_domain` and
configure/whitelist the public hostname as described in
[xtream-domain-whitelist.md](xtream-domain-whitelist.md). The sports feed uses
the same `UpstreamPolicy`: X-Domain is sent only to registered panel hosts,
never to an unrelated redirect target. No environment secret or URL belongs
in the Oban job arguments; jobs carry only a provider ID.

`SyncGamesWorker` dispatches every ten minutes on the existing `sync` queue.
It selects only active, flagged Xtream providers, deduplicates pending jobs,
rechecks the flag before fetching, and prunes matches whose end time is more
than twelve hours old. Disable the flag to hide matches immediately from new
listings and skip queued sync jobs. Open rails refresh every minute.

## Ingestion and identity

`XtreamClient.get_games/2` fetches `/api/jogos/<username>/<password>` with Req,
manual SSRF-validated redirects, registered URL-chain failover, bounded
response size (1 MiB / 1000 items), and fixed request timeouts. Transport,
status and JSON failures return a safe atom and preserve existing matches.
Malformed entries are skipped. Raw bodies, credentials and player URLs are
never stored or logged by the feature; diagnostic redaction also recognizes
the sports credential path.

The payload has no external match ID. Its stable key hashes normalized league,
home name, away name and kickoff timestamp, scoped by provider. Repeated polls
and title/logo/end-time changes update one row; distinct kickoffs preserve
same-day doubleheaders. A changed kickoff creates a new identity; the former
row expires under normal pruning. Provider `timer.day` is not trusted for
calendar filtering: the epoch timestamps are authoritative.

Each candidate player URL must belong to a registered panel host and match
that provider's credential-bearing live path. Only the numeric stream ID is
used transiently to find a channel within the same provider; the first existing
candidate wins. Missing mappings are nullable and retried on the next sync.
Channel deletion nulls the mapping; provider deletion removes its matches.
Logo URLs containing credentials are discarded.

## Visibility and presentation

The query reuses the live-channel listing filters: public/global or owned
private providers, provider active/health state, Xtream type, recently-dead
channel exclusion and adult-content preference. Missing channels and disabled
feeds never appear. The TV endpoint uses the same public/API-key pipeline as
`/catalog/channels`, so private providers are never exposed there.

“Today” and displayed kickoff times use PostgreSQL's `America/Sao_Paulo`
timezone rules, not the server/browser timezone. Ongoing overnight matches
remain visible; a match that has ended is left out, since its channel has
moved on and it is no longer playable as a game. Results order live first, then kickoff and ID; `live` means
`starts_at <= now < ends_at`. The rail uses LiveView streams and refreshed
server-side state. Logos always go through the existing image proxy helper,
including HTTPS origins, rather than hotlinking.

## TV contract

Unlike the other catalog collections, this endpoint returns a bare array:

```json
[
  {
    "id": 42,
    "league": "Campeonato Italiano",
    "title": "Monza vs Cagliari",
    "home": {"name": "Monza", "logo_url": "https://images.example.test/proxy?url=https%3A%2F%2Forigin.example.test%2Fhome.png"},
    "away": {"name": "Cagliari", "logo_url": null},
    "starts_at": "2026-10-19T18:00:00Z",
    "ends_at": "2026-10-19T20:00:00Z",
    "live": true,
    "channel_id": 123
  }
]
```

Times are UTC ISO 8601. Logos may be null. `channel_id` is the existing
Streamix live-channel ID, not the provider's stream ID. Empty results are `[]`.
The OpenAPI operation is `catalog.games.list`; authentication failures follow
the existing 401 error envelope.
