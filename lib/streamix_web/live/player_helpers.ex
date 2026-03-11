defmodule StreamixWeb.PlayerHelpers do
  @moduledoc """
  Shared helpers for loading playable content.
  Used by PlayerLive and WatchPartyLive.Show.
  """

  alias Streamix.Iptv
  alias Streamix.Iptv.Gindex
  alias StreamixWeb.Helpers.ImageProxy

  def load_content("live_channel", id, user_id) do
    case Iptv.get_playable_channel(user_id, id) do
      nil -> {:error, :not_found}
      channel -> load_channel(channel)
    end
  end

  def load_content("movie", id, user_id) do
    case Iptv.get_playable_movie(user_id, id) do
      nil -> {:error, :not_found}
      movie -> load_movie(movie)
    end
  end

  def load_content("episode", id, user_id) do
    case Iptv.get_playable_episode(user_id, id) do
      nil -> {:error, :not_found}
      episode -> load_episode(episode)
    end
  end

  def load_content("gindex", id, _user_id) do
    movie = Iptv.get_movie_with_provider!(id)

    if movie && movie.gindex_path do
      load_gindex_movie(movie)
    else
      {:error, :not_found}
    end
  rescue
    Ecto.NoResultsError -> {:error, :not_found}
  end

  def load_content("gindex_episode", id, _user_id) do
    episode = Iptv.get_episode_with_context!(id)

    if episode && episode.gindex_path do
      load_gindex_episode(episode)
    else
      {:error, :not_found}
    end
  rescue
    Ecto.NoResultsError -> {:error, :not_found}
  end

  def load_content(_, _, _), do: {:error, :not_found}

  def load_next_episode(type, content, provider) when type in ["episode", "gindex_episode"] do
    case Iptv.get_next_episode(content.id) do
      nil ->
        nil

      next ->
        stream_url =
          case type do
            "episode" -> Iptv.Episode.stream_url(next, provider)
            "gindex_episode" -> get_gindex_episode_url(next)
          end

        %{
          id: next.id,
          title: next.title || "Episódio #{next.episode_num}",
          episode_num: next.episode_num,
          season_num: next.season.season_number,
          series_name: next.season.series.name,
          cover: ImageProxy.proxy(next.cover || next.still_path),
          stream_url: stream_url,
          type: type
        }
    end
  end

  def load_next_episode(_, _, _), do: nil

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

  defp load_channel(channel) do
    provider = channel.provider
    stream_url = Iptv.LiveChannel.stream_url(channel, provider)
    {:ok, channel, provider, stream_url}
  end

  defp load_movie(movie) do
    provider = movie.provider
    stream_url = Iptv.Movie.stream_url(movie, provider)
    {:ok, movie, provider, stream_url}
  end

  defp load_episode(episode) do
    provider = episode.season.series.provider
    stream_url = Iptv.Episode.stream_url(episode, provider)
    {:ok, episode, provider, stream_url}
  end

  defp load_gindex_movie(movie) do
    provider = movie.provider

    case Gindex.get_movie_url(movie.id) do
      {:ok, stream_url} -> {:ok, movie, provider, stream_url}
      {:error, _reason} -> {:error, :not_found}
    end
  end

  defp load_gindex_episode(episode) do
    provider = episode.season.series.provider

    case Gindex.get_episode_url(episode.id) do
      {:ok, stream_url} -> {:ok, episode, provider, stream_url}
      {:error, _reason} -> {:error, :not_found}
    end
  end

  defp get_gindex_episode_url(episode) do
    case Gindex.get_episode_url(episode.id) do
      {:ok, url} -> url
      _ -> nil
    end
  end
end
