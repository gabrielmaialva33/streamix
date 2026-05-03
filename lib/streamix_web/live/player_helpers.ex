defmodule StreamixWeb.PlayerHelpers do
  @moduledoc """
  Shared helpers for loading playable content.
  Used by PlayerLive and WatchPartyLive.Show.
  """

  alias Streamix.Access
  alias Streamix.Iptv
  alias Streamix.Iptv.Gindex
  alias Streamix.Iptv.Streaming.RedirectResolver
  alias Streamix.Iptv.Streaming.SourceUrl
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

  def load_content(_, _, _), do: {:error, :not_found}

  def load_content_preflight("live_channel", id, user_id) do
    case Iptv.get_playable_channel(user_id, id) do
      nil -> {:error, :not_found}
      channel -> {:ok, channel, channel.provider}
    end
  end

  def load_content_preflight("movie", id, user_id) do
    case Iptv.get_playable_movie(user_id, id) do
      nil -> {:error, :not_found}
      movie -> {:ok, movie, movie.provider}
    end
  end

  def load_content_preflight("episode", id, user_id) do
    case Iptv.get_playable_episode(user_id, id) do
      nil -> {:error, :not_found}
      episode -> {:ok, episode, episode.season.series.provider}
    end
  end

  def load_content_preflight("gindex", id, _user_id) do
    movie = Iptv.get_movie_with_provider!(id)

    if movie.gindex_path do
      {:ok, movie, movie.provider}
    else
      {:error, :not_found}
    end
  rescue
    Ecto.NoResultsError -> {:error, :not_found}
  end

  def load_content_preflight("gindex_episode", id, _user_id) do
    episode = Iptv.get_episode_with_context!(id)

    if episode.gindex_path do
      {:ok, episode, episode.season.series.provider}
    else
      {:error, :not_found}
    end
  rescue
    Ecto.NoResultsError -> {:error, :not_found}
  end

  def load_content_preflight(_, _, _), do: {:error, :not_found}

  def load_next_episode(type, content, provider, user_id \\ nil)

  def load_next_episode(type, content, _provider, user_id)
      when type in ["episode", "gindex_episode"] do
    case Iptv.get_next_episode(content.id) do
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

  def content_title(content, "episode"),
    do: content.title || "Episódio #{content.episode_num || ""}"

  def content_title(content, "gindex_episode"),
    do: content.title || "Episódio #{content.episode_num || ""}"

  def content_title(content, _), do: content.name

  def content_icon(content, "live_channel"), do: content.stream_icon
  def content_icon(content, "movie"), do: content.stream_icon || Map.get(content, :cover)
  def content_icon(content, "gindex"), do: content.stream_icon
  def content_icon(content, "episode"), do: Map.get(content, :cover)
  def content_icon(content, "gindex_episode"), do: Map.get(content, :cover)
  def content_icon(_, _), do: nil

  def default_streaming_mode("live_channel"), do: :balanced
  def default_streaming_mode(_), do: :adaptive

  # --- Private ---

  def resolve_stream_url("live_channel", channel, _provider, user_id) do
    # Live channels stream directly through the BEAM (chunked send),
    # so the direct-source fast path doesn't apply. Always use the
    # token proxy.
    token = StreamToken.sign_channel(channel.id, user_id)
    {:ok, build_token_proxy_url(token)}
  end

  def resolve_stream_url("movie", movie, _provider, user_id) do
    token = StreamToken.sign_movie(movie.id, user_id)
    {:ok, vod_stream_url("movie", movie.id, user_id, token)}
  end

  def resolve_stream_url("episode", episode, _provider, user_id) do
    token = StreamToken.sign_episode(episode.id, user_id)
    {:ok, vod_stream_url("episode", episode.id, user_id, token)}
  end

  def resolve_stream_url("gindex", movie, _provider, user_id) do
    case Gindex.get_movie_url(movie.id) do
      {:ok, raw_url} ->
        {:ok, sign_and_build_url_proxy(raw_url, user_id, movie.provider)}

      {:error, _reason} ->
        {:error, :not_found}
    end
  end

  def resolve_stream_url("gindex_episode", episode, _provider, user_id) do
    case Gindex.get_episode_url(episode.id) do
      {:ok, raw_url} ->
        {:ok, sign_and_build_url_proxy(raw_url, user_id, episode.season.series.provider)}

      {:error, _reason} ->
        {:error, :not_found}
    end
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
    case content_id(content) do
      nil -> :ok
      id -> do_prewarm(type, id, user_id)
    end
  end

  def prewarm_upstream_redirect(_type, _content, _user_id), do: :ok

  defp do_prewarm(type, id, user_id) do
    with {:ok, upstream_type} <- prewarmable_upstream_type(type),
         {:ok, url} <- StreamToken.upstream_url(upstream_type, id, user_id) do
      RedirectResolver.prewarm_async(url, stop_fn: prewarm_stop_fn(url))
    else
      _ -> :ok
    end
  end

  defp prewarmable_upstream_type("live_channel"), do: {:ok, "channel"}
  defp prewarmable_upstream_type("movie"), do: {:ok, "movie"}
  defp prewarmable_upstream_type("episode"), do: {:ok, "episode"}
  defp prewarmable_upstream_type(_), do: :skip

  defp prewarm_stop_fn(url) do
    if credentials_in_url?(url) do
      fn next_url -> not credentials_in_url?(next_url) end
    else
      fn _ -> false end
    end
  end

  defp credentials_in_url?(url) do
    case URI.parse(url) do
      %URI{path: path} when is_binary(path) ->
        Regex.match?(~r{/(live|movie|series)/[^/]+/[^/]+/}, path)

      _ ->
        false
    end
  end

  defp content_id(%{id: id}) when is_integer(id), do: id
  defp content_id(_), do: nil

  # VOD fast path: if the redirect-chain resolver already has a hot
  # cache entry for this content (e.g. because the Detail page fired
  # a prewarm a few seconds ago), build a signed URL pointing straight
  # at `source.mahina.cloud`. The browser then skips the Phoenix 302
  # bounce entirely.
  #
  # Cache miss → fall back to the token-redirect path. We deliberately
  # do NOT block the LiveView mount waiting for the resolver to warm
  # up: that path adds noticeable latency for users landing directly
  # on /watch without coming via the detail page, and doesn't help live
  # channels at all. The StreamController on the token path will
  # resolve the chain on its own and the prewarm task fired by mount
  # keeps the cache warm for retries.
  defp vod_stream_url(type, id, user_id, token) do
    with {:ok, upstream_url} <- StreamToken.upstream_url(type, id, user_id),
         {:ok, final_url} <- RedirectResolver.peek(upstream_url),
         {:ok, signed_url} <- SourceUrl.build(final_url) do
      signed_url
    else
      _ -> build_token_proxy_url(token)
    end
  end

  defp get_gindex_episode_url(episode) do
    case Gindex.get_episode_url(episode.id) do
      {:ok, url} -> url
      _ -> nil
    end
  end

  defp next_episode_stream_url("episode", next, user_id) do
    next.id
    |> StreamToken.sign_episode(user_id)
    |> build_token_proxy_url()
  end

  defp next_episode_stream_url("gindex_episode", next, user_id) do
    case get_gindex_episode_url(next) do
      nil -> nil
      url -> sign_and_build_url_proxy(url, user_id, next.season.series.provider)
    end
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

  defp sign_and_build_url_proxy(url, user_id, provider) do
    premium_required = Access.global_content?(provider)

    case StreamToken.sign_url(url, user_id,
           premium_required: premium_required,
           provider_id: provider.id
         ) do
      {:error, _} -> nil
      token -> build_token_proxy_url(token)
    end
  end
end
