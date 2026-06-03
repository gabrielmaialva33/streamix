defmodule StreamixWeb.StreamToken do
  @moduledoc """
  Facade for signed stream tokens.

  Tokens prevent exposing provider credentials in API responses.
  Instead of returning URLs with embedded `username/password`, we return
  a signed token that can be exchanged for the actual stream URL
  server-side. Tokens are bound to a specific `user_id`, ensuring a
  leaked token cannot be used by a different user — the embedded
  `user_id` is verified against provider ownership at consumption time.

  The implementation is split across two focused modules so the signing
  surface stays small and the verification + resolution paths stay
  separated:

  * `StreamixWeb.StreamToken.Signer` — mints tokens.
  * `StreamixWeb.StreamToken.Resolver` — verifies tokens and resolves
    them to upstream URLs (including pre-flight resolution via
    `upstream_url/4` for player prewarm).

  Callers should keep depending on this facade — the sub-modules are
  internal and may be rearranged.
  """

  alias StreamixWeb.StreamToken.{Resolver, Signer}

  @doc """
  Generates a signed token for accessing a movie stream.
  The `user_id` is embedded in the token and verified on consumption.
  Pass `nil` for public/global provider content (catalog API).

  ## Options

    * `:bypass_subscription` — embed an integration-authorized flag inside
      the signed token. Callers that already proved authorization (e.g.
      requests with a valid `X-API-Key` hitting the catalog API) should
      set this so the stream proxy skips the subscription check, even
      when the URL is later fetched by an intermediate proxy that strips
      auth headers. The token signature prevents forgery.
  """
  defdelegate sign_movie(movie_id, user_id, opts \\ []), to: Signer

  @doc "Generates a signed token for accessing an episode stream. See `sign_movie/3` for options."
  defdelegate sign_episode(episode_id, user_id, opts \\ []), to: Signer

  @doc "Generates a signed token for accessing a channel stream. See `sign_movie/3` for options."
  defdelegate sign_channel(channel_id, user_id, opts \\ []), to: Signer

  @doc """
  Generates a signed token for proxying an external URL.
  Used for GIndex and other external sources that need CORS headers.
  The `user_id` is embedded in the token and verified on consumption.
  Pass `provider_id` so provider visibility/ownership can be revalidated
  when the token is consumed.
  """
  defdelegate sign_url(url, user_id, opts \\ []), to: Signer

  @doc """
  Verifies a token and returns the actual stream URL if valid.
  Returns `{:ok, url, content_type, meta}` or `{:error, reason}`.

  `content_type` is "channel", "movie", "episode", or "url".
  `meta` is a map with type-specific fields; always contains `:content_id`
  (the DB id of the resolved channel/movie/episode, or `nil` for raw URL
  tokens) so the stream proxy can act on terminal upstream errors (e.g.
  mark a live channel dead when the upstream returns 404).

  The embedded user_id is checked against provider ownership:
  - If user_id is present, the content's provider must belong to that user
    or be a public/global provider.
  - If user_id is nil (public catalog token), the provider must be public/global.

  ## Options

    * `:bypass_subscription` — when `true`, skips the subscription / premium
      access check for global-provider content. The caller is responsible
      for establishing authorization out-of-band (e.g. by validating a
      privileged `X-API-Key` on the request before calling verify). Token
      signature + provider visibility are still verified. Default: `false`.
  """
  defdelegate verify_and_get_url(token, opts \\ []), to: Resolver

  @doc """
  Returns the raw upstream URL that the given content would resolve to
  if its token were verified.

  Used by `PlayerLive.mount/3` to prewarm the redirect-chain resolver
  without round-tripping through the signed-token exchange. The same
  authorization checks as `verify_and_get_url/2` are applied — a user
  who is not allowed to play the content gets `{:error, …}` here too.
  """
  defdelegate upstream_url(type, id, user_id, opts \\ []), to: Resolver
end
