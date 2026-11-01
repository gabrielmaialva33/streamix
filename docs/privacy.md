# What the operator cannot see

Streamix keeps one promise about viewing data: **whoever runs the instance
cannot tell which movies, episodes or channels a user watched or favorited.**
That covers everything an operator holds at rest — the database and its
backups, Redis, Qdrant, the logs — and the admin panel.

The repository is open source, so the guarantee cannot rest on a secret in the
code or in the deployment's configuration: anyone can read the first, and the
operator holds the second. It rests on a key only the user's password can open.

## How

### One key per user, opened by the password

Each user has a random 32-byte library key (`Streamix.Library.Key`). It is
never stored in the clear, only wrapped twice with AES-256-GCM
(`Streamix.Library.Keyring`):

| Wrap | Stored in | Opened with |
|------|-----------|-------------|
| Password wrap | `library_keys` | PBKDF2-HMAC-SHA256 of the password, a per-user salt, 600 000 iterations |
| Session wrap | `users_tokens.library_key` | HKDF of a random 32-byte secret that only the client holds |

The password reaches the server only at login, which is when the key is
unlocked and wrapped for the new session. The session secret goes back to the
client and is never written server-side:

- **web**: in the session cookie, which is encrypted, and in the encrypted
  remember-me cookie;
- **REST API**: as the second half of the bearer token (URL-safe base64 of the
  32-byte session token followed by the 32-byte secret).

Each request opens the session wrap with the secret it carries, so the key
lives only in memory while the request or LiveView runs. `Inspect` never prints
it. Logging out deletes the session row, and with it the wrap.

The key is derived from the bytes bcrypt verifies (the first 72), so every
password the login accepts opens it. Changing the password with the current
one re-wraps the same key; history and favorites survive. Replacing it without
the current one (no UI offers this) discards the library, because nobody can
open it anymore. That is the only path that ever discards a key: a verified
password that does not open the stored key is refused, never "fixed" by
issuing a new one.

### Sealed rows

`sealed_watch_progress` and `sealed_favorites` hold, besides the owner's
`user_id`:

- `sealed`: the entry (catalog item, progress, completion, and when it was
  watched or favorited) as AES-256-GCM ciphertext under a key derived from the
  user's key, padded to 256-byte blocks so its length gives nothing away. The
  additional data names the table and the user, so a row copied to another
  user or table does not open.
- `item_digest`: HMAC-SHA256 under another derived key. It lets the owner find
  "my progress on this movie" with an index lookup; without the key it means
  nothing. The same movie gives a different digest for every user, and in
  each table, so favorites and history cannot be matched against each other.

There are no plaintext timestamps and no per-series index: when something was
watched, and which entries belong to the same show, live inside `sealed`.
Nothing references `catalog_items`, so the database cannot join a user to
content. Listings open the user's rows in memory and resolve the catalog
afterwards. When a sync replaces a catalog item (a GIndex duplicate, for
instance), it leaves a `catalog_item_redirects` row naming only the two items;
the owner's next read moves their entry to the successor.

### Nothing derived from the history leaves the session

- The taste profile, viewing insights, recommendations and personalized home
  shelves are computed with the user's key and cached in the node's memory
  only (`Streamix.Cache.fetch_personal/4`), never in Redis, Qdrant or the
  database. The Qdrant `user_profiles` collection is gone: a stored taste
  vector can be searched for the titles nearest to it.
- "Em alta" no longer counts what people watch. On a small instance even an
  anonymous per-title counter gives a viewer away: it moves while only one
  person is streaming. Trending shelves rank recent, well-rated titles.
- Playback sessions (the screen limit) record that a screen is in use, not
  what it plays, and are deleted when playback ends.
- Playback quality samples (QoE) keep a content type such as `movie` and a
  time, but no user: their dedupe hash is keyed with the user's key.
- Ended Watch Party rooms, which name content and participants, are purged a
  day after they end.
- Content of a private (personal) provider bypasses the on-disk VOD block
  cache, whose file names derive from provider and content: only the
  provider's owner can play that content, so the cache would say what they
  watched.

### Logs

On a personal provider, the content alone names the person watching it, so
logs must name neither the user nor the content:

- Request lines show the route pattern (`GET /watch/:type/:id -> 200`), never
  the path, and carry no `user_id`. Stream tokens, secrets and the LiveView
  `_client_id` are redacted wherever Phoenix logs parameters.
- Stream tokens are encrypted (`Phoenix.Token.encrypt/3`), not just signed, so
  the user and content in their claims do not show in URLs.
- Streaming logs replace content ids, stream keys and torrent hashes with
  `Streamix.SafeLog.content_ref/1`: an HMAC under a random secret that exists
  only in the node's memory, so a run's lines about one title correlate but
  never map back to it. Upstream URLs lose their stream ids along with the
  credentials.
- The audit line for subscription bypasses names the stream type and provider,
  not the user or the content.
- `docs/nginx-stream-proxy.conf` logs the path only, without query string,
  `Referer` or client address: query strings carry stream ids and tokens,
  poster paths name titles, a player request's referer is the watch page, and
  a client IP maps to an account through its sessions. Keep the same rule on
  any reverse proxy in front of Streamix, including the GIndex `/stream`
  proxy.

## What this does not cover

Being precise about the limits is part of the promise:

- **A running server is trusted during a session.** It holds the key in memory
  to render the user's pages, and it sees the password at login. An operator
  who changes the code or its configuration, or inspects the live process,
  could capture both — for instance, at `debug` log level LiveView prints the
  session, secret included, so production must never run at `debug`. Open
  source lets anyone check what this code does; it cannot prove what a given
  server runs.
- **Weak passwords can be guessed offline.** A database backup holds the
  bcrypt hash and the password wrap; whoever has one can try passwords
  against either. The key is only as strong as the password.
- **What is playing right now** is visible to someone watching the live
  system: in-memory stream multiplexers, the 60-second redirect cache, active
  playback slots, request timing.
- **Watch Party** needs the server to know, while a room exists, what it plays
  and who is in it, and participants see each other.
- **Upstream providers** see the streams Streamix requests, under Streamix's
  account rather than the user's.
- **Network observation** — matching a user's IP to stream traffic as it
  happens — is outside the application.
- **Account activity** — logins, sessions, the number of entries a user has —
  stays visible, never what those entries are.
- **Backups** taken before the upgrade still hold the old plaintext tables,
  and comparing two backups shows that a user's entry was dropped or moved
  after a sync removed some titles, which narrows what it pointed at.

## Operating the upgrade

- Deploying the encrypted library ends every session once. The session cookie
  changed, and sessions without a key cannot read the library. TV and mobile
  apps must log in again; their new bearer token is 88 characters.
- The schema change is an expand step: it only adds tables and columns,
  clears data and relaxes constraints, so the previous image keeps working
  against it while the deploy swaps containers and after an image rollback.
- Plaintext history and favorites from before the upgrade stay in the original
  `watch_progress` and `favorites` tables. Each user's rows are sealed into
  `sealed_watch_progress` and `sealed_favorites` and deleted from the originals
  at their next login. Rows of users who do not come back stay readable until
  the operator purges them:

  ```bash
  bin/streamix eval "Streamix.Library.purge_legacy_plaintext()"
  ```

- The migration empties `watch_events` (no reader, content next to IP
  addresses) and the ended rows of `playback_sessions`, and clears the content
  of `playback_sessions` and the `user_id` of `qoe_events`. The new code never
  writes those columns.
- A later contract release retires the plaintext tables, `watch_events` and
  the cleared columns, once no deployable image reads them. Until then an
  image rollback runs the previous release against the new schema: it works,
  but it writes plaintext again until the new image is back.
- Qdrant's `user_profiles` collection is dropped by the collection bootstrap
  job at boot. Personalization older releases left in Redis expires within
  three hours.
