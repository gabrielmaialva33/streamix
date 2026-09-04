defmodule StreamixWeb.PlayerHelpers do
  @moduledoc """
  Shared helpers for loading playable content.
  Used by PlayerLive and WatchPartyLive.Show.
  """
  alias Streamix.Torrent
  alias StreamixWeb.Helpers.ImageProxy
  alias StreamixWeb.StreamToken

  def load_content("live_channel", id, user_id) do
    with {:ok, channel, provider} <- load_content_preflight("live_channel", id, user_id),
         {:ok, stream_url} <- resolve_stream_url("live_channel", channel, provider, user_id) do
      {:ok, channel, provider, stream_url}
    end
  end

  def load_content("movie", id, user_id) do
    with {:ok, movie, provider} <- load_content_preflight("movie", id, user_id),
         {:ok, stream_url} <- resolve_stream_url("movie", movie, provider, user_id) do
      {:ok, movie, provider, stream_url}
    end
  end

  def load_content("episode", id, user_id) do
    with {:ok, episode, provider} <- load_content_preflight("episode", id, user_id),
         {:ok, stream_url} <- resolve_stream_url("episode", episode, provider, user_id) do
      {:ok, episode, provider, stream_url}
    end
  end

  def load_content("gindex", id, user_id) do
    with {:ok, movie, provider} <- load_content_preflight("gindex", id, user_id),
         {:ok, stream_url} <- resolve_stream_url("gindex", movie, provider, user_id) do
      {:ok, movie, provider, stream_url}
    end
  end

  def load_content("gindex_episode", id, user_id) do
    with {:ok, episode, provider} <- load_content_preflight("gindex_episode", id, user_id),
         {:ok, stream_url} <- resolve_stream_url("gindex_episode", episode, provider, user_id) do
      {:ok, episode, provider, stream_url}
    end
  end

  def load_content("torrent", id, user_id) do
    with {:ok, content, provider} <- load_content_preflight("torrent", id, user_id),
         {:ok, stream_url} <- resolve_stream_url("torrent", content, provider, user_id) do
      {:ok, content, provider, stream_url}
    end
  end

  def load_content(_, _, _), do: {:error, :not_found}

  @doc """
  Per-tab client identity sent by the browser as the `_client_id` connect
  param. Only available on the connected mount; `nil` on the static render and
  for clients that do not send it.
  """
  @spec client_id_from_socket(Phoenix.LiveView.Socket.t()) :: String.t() | nil
  def client_id_from_socket(socket) do
    if Phoenix.LiveView.connected?(socket) do
      case Phoenix.LiveView.get_connect_params(socket) do
        %{"_client_id" => client_id} when is_binary(client_id) -> client_id
        _ -> nil
      end
    else
      nil
    end
  end

  def load_content_preflight("live_channel", id, user_id) do
    with {:ok, id} <- parse_id(id),
         %{} = channel <- Streamix.Playback.get_playable_channel(user_id, id) do
      {:ok, channel, channel.provider}
    else
      _ -> {:error, :not_found}
    end
  end

  def load_content_preflight("movie", id, user_id) do
    with {:ok, id} <- parse_id(id),
         %{} = movie <- Streamix.Playback.get_playable_movie(user_id, id) do
      {:ok, movie, movie.provider}
    else
      _ -> {:error, :not_found}
    end
  end

  def load_content_preflight("episode", id, user_id) do
    with {:ok, id} <- parse_id(id),
         %{} = episode <- Streamix.Playback.get_playable_episode(user_id, id) do
      {:ok, episode, episode.season.series.provider}
    else
      _ -> {:error, :not_found}
    end
  end

  def load_content_preflight("gindex", id, _user_id) do
    case parse_id(id) do
      {:ok, id} -> load_gindex_movie(id)
      :error -> {:error, :not_found}
    end
  rescue
    Ecto.NoResultsError -> {:error, :not_found}
  end

  def load_content_preflight("gindex_episode", id, _user_id) do
    case parse_id(id) do
      {:ok, id} -> load_gindex_episode(id)
      :error -> {:error, :not_found}
    end
  rescue
    Ecto.NoResultsError -> {:error, :not_found}
  end

  def load_content_preflight("torrent", id, _user_id) do
    case parse_id(id) do
      {:ok, id} -> load_torrent_stream(id)
      :error -> {:error, :not_found}
    end
  end

  def load_content_preflight(_, _, _), do: {:error, :not_found}

  @doc """
  Resolves the canonical catalog item behind a player surface.

  GIndex rows are canonical movies/episodes, while torrent playback uses the
  associated movie rather than the transient torrent stream id.
  """
  def resolve_catalog_item_id("gindex", %{id: id}),
    do: Streamix.Catalog.resolve_catalog_item_id("movie", id)

  def resolve_catalog_item_id("gindex_episode", %{id: id}),
    do: Streamix.Catalog.resolve_catalog_item_id("episode", id)

  def resolve_catalog_item_id("torrent", %{movie_id: movie_id}),
    do: Streamix.Catalog.resolve_catalog_item_id("movie", movie_id)

  def resolve_catalog_item_id(type, %{id: id})
      when type in ["live_channel", "movie", "series", "episode"] do
    Streamix.Catalog.resolve_catalog_item_id(type, id)
  end

  def resolve_catalog_item_id(_type, _content), do: {:error, :invalid_content_type}

  def canonical_content_type("gindex"), do: "movie"
  def canonical_content_type("gindex_episode"), do: "episode"
  def canonical_content_type("torrent"), do: "movie"
  def canonical_content_type(type), do: type

  @doc "Returns whether a player source can move between equivalent provider copies."
  def automatic_failover_supported?(type, provider) do
    canonical_content_type(to_string(type)) in ["movie", "episode"] and
      Map.get(provider, :provider_type) not in [:torrent, "torrent"]
  end

  @doc """
  Returns equivalent visible playback sources ranked by runtime health.

  The current source remains in the result so callers can preserve one common
  ordering contract and exclude already-attempted ids locally. Torrent-backed
  movie rows are intentionally omitted because switching to them requires the
  swarm-gate lifecycle rather than a URL-only player restart.
  """
  def failover_sources(type, content, user_id) do
    case canonical_content_type(to_string(type)) do
      "movie" -> movie_failover_sources(content, user_id)
      "episode" -> episode_failover_sources(content, user_id)
      _ -> []
    end
  end

  defp movie_failover_sources(movie, user_id) do
    [movie | Streamix.Playback.list_movie_variants(movie, user_id, limit: 32)]
    |> Enum.uniq_by(& &1.id)
    |> Enum.reject(&(Map.get(&1.provider, :provider_type) in [:torrent, "torrent"]))
    |> Enum.map(&source_candidate("movie", &1, &1.provider))
    |> Streamix.Playback.sort_stream_sources(media_type: :vod, current_source_id: movie.id)
  end

  defp episode_failover_sources(
         %{season: %{season_number: season_number, series: series}} = episode,
         user_id
       ) do
    current_provider = series.provider

    alternatives =
      series
      |> Streamix.Playback.list_series_variants(user_id, limit: 24)
      |> Enum.flat_map(fn candidate_series ->
        case matching_episode(candidate_series, season_number, episode.episode_num) do
          nil -> []
          candidate -> [source_candidate("episode", candidate, candidate_series.provider)]
        end
      end)

    [source_candidate("episode", episode, current_provider) | alternatives]
    |> Enum.uniq_by(& &1.id)
    |> Streamix.Playback.sort_stream_sources(media_type: :vod, current_source_id: episode.id)
  end

  defp episode_failover_sources(_episode, _user_id), do: []

  defp matching_episode(series, season_number, episode_number) do
    with seasons when is_list(seasons) <- Map.get(series, :seasons),
         season when not is_nil(season) <-
           Enum.find(seasons, &(Map.get(&1, :season_number) == season_number)),
         episodes when is_list(episodes) <- Map.get(season, :episodes) do
      Enum.find(episodes, &(Map.get(&1, :episode_num) == episode_number))
    else
      _ -> nil
    end
  end

  defp source_candidate(type, content, provider) do
    %{
      id: content.id,
      content_id: content.id,
      content_type: type,
      content: content,
      provider: provider,
      provider_id: provider.id,
      name: Map.get(content, :name) || Map.get(content, :title),
      title: Map.get(content, :title) || Map.get(content, :name),
      duration_secs: Map.get(content, :duration_secs),
      tmdb_id: Map.get(content, :tmdb_id)
    }
  end

  defp load_gindex_movie(id) do
    movie = Streamix.Catalog.get_movie_with_provider!(id)

    if movie.gindex_path do
      {:ok, movie, movie.provider}
    else
      {:error, :not_found}
    end
  end

  defp load_gindex_episode(id) do
    episode = Streamix.Catalog.get_episode_with_context!(id)

    if episode.gindex_path do
      {:ok, episode, episode.season.series.provider}
    else
      {:error, :not_found}
    end
  end

  def load_next_episode(type, content, provider, user_id \\ nil)

  def load_next_episode(type, content, _provider, user_id)
      when type in ["episode", "gindex_episode"] do
    case Streamix.Catalog.get_next_episode(content.id) do
      nil ->
        nil

      next ->
        build_next_episode_payload(next, type, user_id)
    end
  end

  def load_next_episode(_, _, _, _), do: nil

  def content_title(content, "live_channel"), do: content.name
  def content_title(content, "movie"), do: content.title || content.name
  def content_title(content, "gindex"), do: content.title || content.name
  def content_title(content, "torrent"), do: content.title || content.name

  def content_title(content, "episode"),
    do: content.title || "Episódio #{content.episode_num || ""}"

  def content_title(content, "gindex_episode"),
    do: content.title || "Episódio #{content.episode_num || ""}"

  def content_title(content, _), do: content.name

  def content_icon(content, "live_channel"), do: content.stream_icon
  def content_icon(content, "movie"), do: content.stream_icon || Map.get(content, :cover)
  def content_icon(content, "gindex"), do: content.stream_icon
  def content_icon(content, "torrent"), do: content.stream_icon || Map.get(content, :cover)
  def content_icon(content, "episode"), do: Map.get(content, :cover)
  def content_icon(content, "gindex_episode"), do: Map.get(content, :cover)
  def content_icon(_, _), do: nil

  def default_streaming_mode("live_channel"), do: :balanced
  def default_streaming_mode(_), do: :adaptive

  # --- Private ---

  def resolve_stream_url("live_channel", channel, _provider, user_id) do
    token = StreamToken.sign_channel(channel.id, user_id)
    {:ok, build_token_proxy_url(token)}
  end

  def resolve_stream_url("movie", movie, _provider, user_id) do
    token = StreamToken.sign_movie(movie.id, user_id)

    if gindex_content?(movie) do
      # 4K HEVC GIndex content streams direct from the nginx hop
      # (`gindex.mahina.fun/stream`) — keeps the BEAM out of the
      # bytes path and lets the browser-side h265web.js engine open
      # the stream URL it can pump straight into the canvas.
      {:ok, build_gindex_stream_url(token)}
    else
      {:ok, build_token_proxy_url(token)}
    end
  end

  def resolve_stream_url("episode", episode, _provider, user_id) do
    token = StreamToken.sign_episode(episode.id, user_id)

    if gindex_content?(episode) do
      {:ok, build_gindex_stream_url(token)}
    else
      {:ok, build_token_proxy_url(token)}
    end
  end

  def resolve_stream_url("gindex", movie, _provider, user_id) do
    token = StreamToken.sign_movie(movie.id, user_id)
    {:ok, build_gindex_stream_url(token)}
  end

  def resolve_stream_url("gindex_episode", episode, _provider, user_id) do
    token = StreamToken.sign_episode(episode.id, user_id)
    {:ok, build_gindex_stream_url(token)}
  end

  def resolve_stream_url(
        "torrent",
        %{torrent_stream: %{info_hash: info_hash}},
        _provider,
        _user_id
      ) do
    {:ok, "#{StreamixWeb.Endpoint.url()}/api/stream/torrent/#{info_hash}"}
  end

  def resolve_stream_url(_, _, _, _), do: {:error, :not_found}

  @doc """
  Fire-and-forget prewarm of the redirect chain for the given content.

  Used both by `PlayerLive.mount/3` (when the user actually starts
  playback) and by Detail LiveViews (`/movies/:id`, episodes, etc.) so
  the chain is already resolved by the time the user clicks "Assistir".
  Safe to call when not authorized — `StreamToken.upstream_url/4` returns
  an error and we no-op. Gindex content has direct URLs and skips
  prewarm.
  """
  def prewarm_upstream_redirect(type, content, user_id) when is_map(content) do
    if gindex_content?(content) do
      :ok
    else
      case content_id(content) do
        nil -> :ok
        id -> do_prewarm(type, id, user_id)
      end
    end
  end

  def prewarm_upstream_redirect(_type, _content, _user_id), do: :ok

  defp do_prewarm(type, id, user_id) do
    with {:ok, upstream_type} <- prewarmable_upstream_type(type),
         {:ok, url} <- StreamToken.upstream_url(upstream_type, id, user_id) do
      Streamix.Playback.prewarm_stream_url(url)
    else
      _ -> :ok
    end
  end

  defp prewarmable_upstream_type("live_channel"), do: {:ok, "channel"}
  defp prewarmable_upstream_type("movie"), do: {:ok, "movie"}
  defp prewarmable_upstream_type("episode"), do: {:ok, "episode"}
  defp prewarmable_upstream_type(_), do: :skip

  defp content_id(%{id: id}) when is_integer(id), do: id
  defp content_id(_), do: nil

  defp gindex_content?(%{gindex_path: path}) when is_binary(path) and path != "", do: true
  defp gindex_content?(_content), do: false

  defp next_episode_stream_url("episode", next, user_id) do
    next.id
    |> StreamToken.sign_episode(user_id)
    |> build_token_proxy_url()
  end

  defp next_episode_stream_url("gindex_episode", next, user_id) do
    next.id
    |> StreamToken.sign_episode(user_id)
    |> build_gindex_stream_url()
  end

  defp build_next_episode_payload(next, type, user_id) do
    %{
      id: next.id,
      title: next.title || "Episódio #{next.episode_num}",
      episode_num: next.episode_num,
      season_num: next.season.season_number,
      series_name: next.season.series.name,
      cover: ImageProxy.proxy(next.cover || next.still_path),
      stream_url: next_episode_stream_url(type, next, user_id),
      type: type
    }
  end

  defp build_token_proxy_url(token) do
    base_url = StreamixWeb.Endpoint.url()
    "#{base_url}/api/stream/proxy?token=#{URI.encode_www_form(token)}"
  end

  defp build_gindex_stream_url(token) do
    case Application.get_env(:streamix, :gindex_direct_proxy_url) do
      base when is_binary(base) and base != "" ->
        "#{String.trim_trailing(base, "/")}/stream?token=#{URI.encode_www_form(token)}"

      _ ->
        build_token_proxy_url(token)
    end
  end

  defp parse_id(id) when is_integer(id), do: {:ok, id}

  defp parse_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {id, ""} when id > 0 -> {:ok, id}
      _ -> :error
    end
  end

  defp parse_id(_), do: :error

  defp load_torrent_stream(id) do
    case Torrent.get_stream_for_playback(id) do
      {:ok, stream, movie, provider} ->
        {:ok, torrent_movie_content(movie, stream), provider}

      :not_found ->
        {:error, :not_found}
    end
  end

  defp torrent_movie_content(movie, stream) do
    %{
      id: stream.id,
      movie_id: movie.id,
      name: movie.name,
      title: movie.title || movie.name,
      imdb_id: movie.imdb_id,
      stream_icon: movie.stream_icon,
      cover: movie.stream_icon,
      duration_secs: movie.duration_secs,
      torrent_stream: stream
    }
  end
end
