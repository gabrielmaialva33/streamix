defmodule StreamixWeb.PlayerLive do
  @moduledoc """
  Fullscreen video player LiveView.

  Supports playback of:
  - Live channels
  - Movies (VOD)
  - Episodes (VOD)
  - GIndex movies (dynamic URL with 30min cache)

  Features:
  - Adaptive streaming with dynamic mode switching
  - Quality selection
  - Audio/subtitle track selection
  - Picture-in-Picture
  - Progress tracking for VOD content
  - Watch history recording
  """
  use StreamixWeb, :live_view

  import StreamixWeb.PlayerComponents

  alias Streamix.Iptv
  alias Streamix.Iptv.Gindex

  @doc false
  def mount(%{"type" => type, "id" => id}, _session, socket) do
    user_id = socket.assigns.current_scope.user.id

    case load_content(type, id, user_id) do
      {:ok, content, provider, stream_url} ->
        record_watch_history(user_id, type, content)

        if connected?(socket) do
          Phoenix.PubSub.subscribe(Streamix.PubSub, "user:#{user_id}:progress")
        end

        socket =
          socket
          |> assign(page_title: content_title(content, type))
          |> assign(content_type: String.to_atom(type))
          |> assign(content: content)
          |> assign(provider: provider)
          |> assign(stream_url: stream_url)
          |> assign(streaming_mode: default_streaming_mode(type))
          |> assign(player_state: :loading)
          |> assign(current_time: 0)
          |> assign(duration: 0)
          |> assign(buffering: false)
          |> assign(pip_active: false)
          |> assign(available_qualities: [])
          |> assign(current_quality: "Automático")
          |> assign(audio_tracks: [])
          |> assign(subtitle_tracks: [])
          |> assign(user_id: user_id)

        {:ok, socket}

      {:error, :not_found} ->
        {:ok,
         socket
         |> put_flash(:error, "Conteúdo não encontrado")
         |> push_navigate(to: ~p"/")}
    end
  end

  # ============================================
  # Event Handlers
  # ============================================

  @doc false
  def handle_event(
        "progress_update",
        %{"current_time" => current_time, "duration" => duration},
        socket
      ) do
    user_id = socket.assigns.user_id
    content = socket.assigns.content
    type = Atom.to_string(socket.assigns.content_type)

    # Update progress in database for VOD content (only for logged-in users)
    if user_id && socket.assigns.content_type != :live do
      Iptv.update_watch_progress(user_id, type, content.id, current_time, duration)
    end

    {:noreply, assign(socket, current_time: current_time, duration: duration)}
  end

  def handle_event("streaming_mode_changed", %{"mode" => mode}, socket) do
    {:noreply, assign(socket, streaming_mode: String.to_atom(mode))}
  end

  def handle_event(
        "qualities_available",
        %{"qualities" => qualities, "current" => current},
        socket
      ) do
    {:noreply,
     assign(socket,
       available_qualities: qualities,
       current_quality: find_quality_label(qualities, current)
     )}
  end

  def handle_event("quality_changed", %{"quality" => quality}, socket) do
    {:noreply, assign(socket, current_quality: quality)}
  end

  def handle_event("audio_tracks_available", %{"tracks" => tracks}, socket) do
    {:noreply, assign(socket, audio_tracks: tracks)}
  end

  def handle_event("subtitle_tracks_available", %{"tracks" => tracks}, socket) do
    {:noreply, assign(socket, subtitle_tracks: tracks)}
  end

  def handle_event("buffering", %{"buffering" => buffering}, socket) do
    {:noreply, assign(socket, buffering: buffering)}
  end

  def handle_event("pip_toggled", %{"active" => active}, socket) do
    {:noreply, assign(socket, pip_active: active)}
  end

  def handle_event("player_initializing", params, socket) do
    {:noreply, assign(socket, player_state: :initializing, stream_type: params["stream_type"])}
  end

  def handle_event("update_watch_time", %{"duration" => duration}, socket) do
    user_id = socket.assigns.user_id

    # Only update watch time for logged-in users
    if user_id do
      content = socket.assigns.content
      type = Atom.to_string(socket.assigns.content_type)
      Iptv.update_watch_time(user_id, type, content.id, duration)
    end

    {:noreply, socket}
  end

  def handle_event("set_quality", %{"level" => level}, socket) do
    {:noreply, push_event(socket, "set_quality", %{level: level})}
  end

  def handle_event("set_audio_track", %{"track" => track}, socket) do
    {:noreply, push_event(socket, "set_audio_track", %{track: track})}
  end

  def handle_event("set_subtitle_track", %{"track" => track}, socket) do
    {:noreply, push_event(socket, "set_subtitle_track", %{track: track})}
  end

  def handle_event("toggle_pip", _, socket) do
    {:noreply, push_event(socket, "toggle_pip", %{})}
  end

  def handle_event("close_player", _, socket) do
    back_path = get_back_path(socket)
    {:noreply, push_navigate(socket, to: back_path)}
  end

  # Events from JS that we don't need to handle but must acknowledge
  def handle_event("quality_switched", _params, socket), do: {:noreply, socket}
  def handle_event("playback_rate_changed", _params, socket), do: {:noreply, socket}
  def handle_event("duration_available", _params, socket), do: {:noreply, socket}
  def handle_event("mute_toggled", _params, socket), do: {:noreply, socket}
  def handle_event("volume_changed", _params, socket), do: {:noreply, socket}

  # ============================================
  # Render
  # ============================================

  @doc false
  def render(assigns) do
    ~H"""
    <div class="fixed inset-0 bg-black">
      <.video_player
        content={@content}
        content_type={@content_type}
        stream_url={@stream_url}
        streaming_mode={@streaming_mode}
        fullscreen={true}
        on_close="close_player"
        show_controls={true}
      />
    </div>
    """
  end

  # ============================================
  # Private Helpers
  # ============================================

  defp load_content("live_channel", id, user_id) do
    case Iptv.get_playable_channel(user_id, id) do
      nil -> {:error, :not_found}
      channel -> load_channel(channel)
    end
  end

  defp load_content("movie", id, user_id) do
    case Iptv.get_playable_movie(user_id, id) do
      nil -> {:error, :not_found}
      movie -> load_movie(movie)
    end
  end

  defp load_content("episode", id, user_id) do
    case Iptv.get_playable_episode(user_id, id) do
      nil -> {:error, :not_found}
      episode -> load_episode(episode)
    end
  end

  defp load_content("gindex", id, _user_id) do
    movie = Iptv.get_movie_with_provider!(id)

    if movie && movie.gindex_path do
      load_gindex_movie(movie)
    else
      {:error, :not_found}
    end
  rescue
    Ecto.NoResultsError -> {:error, :not_found}
  end

  defp load_content(_, _, _), do: {:error, :not_found}

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
      {:ok, stream_url} ->
        {:ok, movie, provider, stream_url}

      {:error, _reason} ->
        {:error, :not_found}
    end
  end

  defp record_watch_history(user_id, type, content) do
    Iptv.add_to_watch_history(user_id, %{
      content_type: type,
      content_id: content.id,
      content_name: content_title(content, type),
      content_icon: content_icon(content, type)
    })
  end

  defp default_streaming_mode("live_channel"), do: :balanced
  defp default_streaming_mode("gindex"), do: :quality
  defp default_streaming_mode(_), do: :quality

  defp content_title(content, "live_channel"), do: content.name
  defp content_title(content, "movie"), do: content.title || content.name
  defp content_title(content, "gindex"), do: content.title || content.name

  defp content_title(content, "episode"),
    do: content.title || "Episódio #{content.episode_num || ""}"

  defp content_title(content, _), do: content.name

  defp content_icon(content, "live_channel"), do: content.stream_icon
  defp content_icon(content, "movie"), do: content.stream_icon || Map.get(content, :cover)
  defp content_icon(content, "gindex"), do: content.stream_icon
  defp content_icon(content, "episode"), do: Map.get(content, :cover)
  defp content_icon(_, _), do: nil

  defp get_back_path(socket) do
    case socket.assigns.content_type do
      :live_channel ->
        ~p"/providers/#{socket.assigns.provider.id}"

      :movie ->
        ~p"/providers/#{socket.assigns.provider.id}/movies"

      :gindex ->
        ~p"/gindex/movies"

      :episode ->
        series_id = socket.assigns.content.season.series_id
        ~p"/providers/#{socket.assigns.provider.id}/series/#{series_id}"

      _ ->
        ~p"/"
    end
  end

  defp find_quality_label(qualities, level) when is_list(qualities) do
    case Enum.find(qualities, fn q -> q["index"] == level end) do
      %{"label" => label} -> label
      _ -> "Automático"
    end
  end

  defp find_quality_label(_, _), do: "Automático"
end
