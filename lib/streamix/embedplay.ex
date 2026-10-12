defmodule Streamix.Embedplay do
  @moduledoc """
  Boundary for the optional Embedplay movie catalog and private HLS gateway.

  Upstream addresses and request headers stay inside this context. Clients
  receive only opaque resource identifiers authorized by StreamToken.

  Resolution health is watched continuously (`Streamix.Embedplay.Health`).
  While resolution is systematically failing the provider is degraded: its
  catalog is hidden from browsing and `open_movie/1` fails fast with
  `{:error, :provider_degraded}` until a probe resolves again.
  """

  alias Streamix.Embedplay.{Canary, Gateway, Health, Sessions}

  def enabled?, do: config(:enabled, false)

  def config(key, default \\ nil),
    do: Application.get_env(:streamix, :embedplay, [])[key] || default

  defdelegate import_movie(tmdb_id, imdb_id \\ nil), to: Streamix.Embedplay.Catalog
  defdelegate sync_catalog(), to: Streamix.Embedplay.Catalog, as: :sync
  defdelegate enqueue_sync(), to: Streamix.Embedplay.Catalog

  @doc """
  Opens (or reuses) a playback session for `movie`.

  Fails fast with `{:error, :provider_degraded}` while the provider is
  degraded, without starting a resolution; every other outcome is recorded
  for health tracking.
  """
  def open_movie(movie), do: Health.guard(movie, fn -> Sessions.open(movie) end)

  defdelegate fetch_resource(session_id, resource_id, movie_id, opts \\ []), to: Gateway

  defdelegate stream_resource(session_id, resource_id, movie_id, opts, acc, sink),
    to: Gateway

  defdelegate rewrite_playlist(body, base_url, session_id, movie_id, resource_url), to: Gateway
  defdelegate invalidate_session(session_id), to: Sessions, as: :invalidate

  @doc """
  Resolution health: `:status` (`:healthy`, `:degraded` or `:disabled`), the
  persisted `:reason` and `:degraded_at`, whether the operator left the
  provider `:active`, and a `:window` summary of recent outcomes.
  """
  defdelegate health(), to: Health, as: :status

  @doc "Runs one health probe if one is due. See `Streamix.Embedplay.Canary`."
  defdelegate run_canary(), to: Canary, as: :run
end
