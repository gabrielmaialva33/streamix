defmodule StreamixWeb.Content.Detail do
  @moduledoc """
  Shared content-detail operations used by movie, series, and episode LiveViews.
  """

  use StreamixWeb, :verified_routes

  require Logger

  alias Streamix.Access
  alias Streamix.AI.SemanticSearch
  alias Streamix.Iptv
  alias Streamix.Torrent
  alias StreamixWeb.Content.FavoriteState
  alias StreamixWeb.Helpers.ImageProxy

  @provider_unavailable_message "Esse provedor não está disponível para sua conta. " <>
                                  "Pode estar inativo, ter sido removido ou ser privado de outro usuário."

  @doc """
  Resolves the provider for a detail-page mount and hands it to `fun`.

  `:browse` resolves the global provider; `:provider` resolves
  `params["provider_id"]` as a playable provider for the current user.
  When the provider is unavailable, returns the standard
  flash-and-redirect `{:ok, socket}` without invoking `fun`.
  """
  def with_provider(_socket, :browse, _params, fun) do
    fun.(global_provider())
  end

  def with_provider(socket, :provider, %{"provider_id" => provider_id}, fun) do
    user_id = socket.assigns.current_scope.user.id

    case playable_provider(user_id, provider_id) do
      nil ->
        {:ok,
         socket
         |> Phoenix.LiveView.put_flash(:error, @provider_unavailable_message)
         |> Phoenix.LiveView.redirect(to: ~p"/")}

      provider ->
        fun.(provider)
    end
  end

  def global_provider, do: Iptv.get_global_provider()

  def playable_provider(user_id, provider_id),
    do: Iptv.get_playable_provider(user_id, provider_id)

  def premium_access?(user, provider), do: Access.plays_global_content?(user, provider)

  @doc "Best (most-seeded) torrent stream for a movie, or nil."
  def best_torrent_stream(movie_id), do: Torrent.best_stream_for_movie(movie_id)

  def premium_access?(user), do: premium_access?(user, global_provider())

  @doc """
  Returns the proxied hero image for a content item: the first backdrop
  asset when present, otherwise the proxied fallback URL.
  """
  def hero_image(content, fallback_url) do
    case Iptv.backdrop_urls(content) do
      [url | _] -> ImageProxy.proxy(url)
      _ -> ImageProxy.proxy(fallback_url)
    end
  end

  def favorite?(nil, _content_type, _content_id), do: false

  def favorite?(user_id, content_type, content_id),
    do: Iptv.favorite?(user_id, content_type, content_id)

  def toggle_movie_favorite(user_id, movie, current) do
    result =
      FavoriteState.toggle(user_id, "movie", movie.id, %{
        content_name: movie.title || movie.name,
        content_icon: movie.stream_icon
      })

    FavoriteState.preserve_boolean(current, result)
  end

  def toggle_series_favorite(user_id, series, current) do
    result =
      FavoriteState.toggle(user_id, "series", series.id, %{
        content_name: series.title || series.name,
        content_icon: series.cover
      })

    FavoriteState.preserve_boolean(current, result)
  end

  def get_playable_movie(user_id, movie_id), do: Iptv.get_playable_movie(user_id, movie_id)
  def get_playable_series(user_id, series_id), do: Iptv.get_playable_series(user_id, series_id)
  def get_series_with_sync!(series_id), do: Iptv.get_series_with_sync!(series_id)
  def get_episode_with_context!(episode_id), do: Iptv.get_episode_with_context!(episode_id)

  def movie_variants(movie, user_id), do: Iptv.list_movie_variants(movie, user_id)
  def series_variants(series, user_id), do: Iptv.list_series_variants(series, user_id)

  def maybe_fetch_movie_info(movie) do
    if needs_detailed_info?(movie) do
      case Iptv.fetch_movie_info(movie) do
        {:ok, updated_movie} -> updated_movie
        {:error, _reason} -> movie
      end
    else
      movie
    end
  end

  def maybe_fetch_series_info(series) do
    if needs_detailed_info?(series) do
      case Iptv.fetch_series_info(series) do
        {:ok, updated_series} -> updated_series
        {:error, _reason} -> series
      end
    else
      series
    end
  end

  def maybe_fetch_episode_info(episode) do
    case Iptv.fetch_episode_info(episode) do
      {:ok, updated_episode} -> updated_episode
      {:error, _reason} -> episode
    end
  end

  def similar_movies(movie_id),
    do: similar(movie_id, :movies, &Iptv.get_movies_by_ids/1, "MovieDetail")

  def similar_series(series_id),
    do: similar(series_id, :series, &Iptv.get_series_by_ids/1, "SeriesDetail")

  def seasons_with_episodes(series) do
    (series.seasons || [])
    |> Enum.reject(fn season -> (season.episodes || []) == [] end)
    |> Enum.sort_by(& &1.season_number)
  end

  def initial_expanded([first | _]), do: MapSet.new([first.id])
  def initial_expanded(_), do: MapSet.new()

  def episode_navigation(episode) do
    season = episode.season
    episodes = Iptv.list_season_episodes(season.id)
    current_index = Enum.find_index(episodes, &(&1.id == episode.id))

    prev_episode = if current_index && current_index > 0, do: Enum.at(episodes, current_index - 1)

    next_episode =
      if current_index && current_index < length(episodes) - 1 do
        Enum.at(episodes, current_index + 1)
      end

    %{
      season: season,
      episodes: episodes,
      prev_episode: prev_episode,
      next_episode: next_episode,
      total_episodes: length(episodes)
    }
  end

  defp needs_detailed_info?(content) do
    missing_basic = is_nil(content.plot)
    missing_extended = is_nil(content.content_rating) and is_nil(content.tagline)

    missing_basic or missing_extended
  end

  defp similar(content_id, type, fetch_full, log_context) do
    case SemanticSearch.similar(content_id, type, limit: 6) do
      {:ok, results} ->
        results
        |> Enum.map(& &1.id)
        |> fetch_full.()

      {:error, reason} ->
        Logger.debug("[#{log_context}] SemanticSearch unavailable: #{inspect(reason)}")
        []
    end
  rescue
    error ->
      Logger.warning("[#{log_context}] Unexpected error in similar lookup: #{inspect(error)}")
      []
  end
end
