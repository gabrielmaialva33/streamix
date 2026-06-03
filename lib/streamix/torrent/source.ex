defmodule Streamix.Torrent.Source do
  @moduledoc """
  Behaviour every torrent source (YTS, EZTV, GratisTorrent, …)
  implements so the sync orchestrator can iterate sources uniformly.

  A source is anything that can hand us a `t:listing_item/0` map: TMDB-
  style metadata (title, year, imdb_id, posters) plus one or more
  `t:magnet_info/0` rows that the orchestrator persists into
  `torrent_streams`.

  Each source owns its own pacing — `rate_limit_ms/0` is consulted by
  the orchestrator before every call to keep us well under whatever
  threshold the upstream tolerates.
  """

  @type listing_item :: %{
          required(:external_id) => String.t(),
          required(:title) => String.t(),
          required(:torrents) => [magnet_info()],
          optional(:year) => integer() | nil,
          optional(:imdb_id) => String.t() | nil,
          optional(:tmdb_id) => String.t() | nil,
          optional(:poster_url) => String.t() | nil,
          optional(:backdrop_url) => String.t() | nil,
          optional(:plot) => String.t() | nil,
          optional(:rating) => float() | nil,
          optional(:runtime_minutes) => integer() | nil,
          optional(:genres) => [String.t()]
        }

  @type magnet_info :: %{
          required(:info_hash) => String.t(),
          required(:magnet_uri) => String.t(),
          required(:source_slug) => String.t(),
          optional(:quality) => String.t() | nil,
          optional(:codec) => String.t() | nil,
          optional(:audio_track) => String.t() | nil,
          optional(:container) => String.t() | nil,
          optional(:size_bytes) => integer() | nil,
          optional(:seeders) => integer(),
          optional(:leechers) => integer()
        }

  @type fetch_opts :: [page: pos_integer(), limit: pos_integer()]

  @doc """
  Slug used as `torrent_streams.source_slug` and as a key for pacing,
  metrics, and logs. Must be stable across deploys.
  """
  @callback slug() :: String.t()

  @doc """
  Display name for admin UIs.
  """
  @callback name() :: String.t()

  @doc """
  Minimum delay between consecutive HTTP requests to this source. The
  orchestrator awaits at least this long before issuing the next call.
  """
  @callback rate_limit_ms() :: pos_integer()

  @doc """
  Page through the source's listing. Returns `{:ok, items, meta}`
  where `meta` carries pagination hints (`:next_page`, `:total`).
  """
  @callback fetch_listing(fetch_opts()) ::
              {:ok, [listing_item()], meta :: map()} | {:error, term()}
end
