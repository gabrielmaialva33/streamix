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

  alias Streamix.{Access, Billing}
  import StreamixWeb.PlayerComponents
  import StreamixWeb.PlayerHelpers

  alias Streamix.Iptv

  @impl true
  def mount(%{"type" => type, "id" => id}, _session, socket) do
    user_id = socket.assigns.current_scope.user.id

    case load_content_preflight(type, id, user_id) do
      {:ok, content, provider} ->
        handle_loaded_content(socket, type, user_id, content, provider)

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

  @impl true
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

    Billing.touch_playback_session(socket.assigns[:playback_session])

    {:noreply, assign(socket, current_time: current_time, duration: duration)}
  end

  def handle_event("streaming_mode_changed", %{"mode" => mode}, socket) do
    {:noreply, assign(socket, streaming_mode: safe_streaming_mode(mode))}
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
    Billing.touch_playback_session(socket.assigns[:playback_session])
    {:noreply, assign(socket, player_state: :initializing, stream_type: params["stream_type"])}
  end

  # Netflix-inspired telemetry events (just log for now, could store for analytics)
  def handle_event("device_diagnostics", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("player_error", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("player_debug", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("codec_abr_suggestion", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("diagnostic_suggestion", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("update_watch_time", %{"duration" => duration}, socket) do
    user_id = socket.assigns.user_id

    # Only update watch time for logged-in users
    if user_id do
      content = socket.assigns.content
      type = Atom.to_string(socket.assigns.content_type)
      Iptv.update_watch_time(user_id, type, content.id, duration)
    end

    Billing.touch_playback_session(socket.assigns[:playback_session])

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
  def handle_event("audio_track_changed", _params, socket), do: {:noreply, socket}
  def handle_event("subtitle_track_changed", _params, socket), do: {:noreply, socket}
  def handle_event("qualities_available", _params, socket), do: {:noreply, socket}
  def handle_event("pip_error", _params, socket), do: {:noreply, socket}
  def handle_event("progress_update", _params, socket), do: {:noreply, socket}
  def handle_event("request_token_refresh", _params, socket), do: {:noreply, socket}
  def handle_event("avplayer_preference_changed", _params, socket), do: {:noreply, socket}

  @impl true
  def terminate(_reason, socket) do
    if Map.has_key?(socket.assigns, :user_id) && socket.assigns.user_id do
      Phoenix.PubSub.unsubscribe(Streamix.PubSub, "user:#{socket.assigns.user_id}:progress")
    end

    if Map.has_key?(socket.assigns, :playback_session) do
      Billing.end_playback_session(socket.assigns.playback_session)
    end

    :ok
  end

  # ============================================
  # Render
  # ============================================

  @impl true
  def render(assigns) do
    ~H"""
    <div class="fixed inset-0 bg-black">
      <.video_player
        content={@content}
        content_type={@content_type}
        stream_url={@stream_url}
        streaming_mode={@streaming_mode}
        provider_type={@provider.provider_type}
        fullscreen={true}
        on_close="close_player"
        show_controls={true}
        next_episode={@next_episode}
        expected_duration={Map.get(@content, :duration_secs, 0) || 0}
      />
    </div>
    """
  end

  # ============================================
  # Private Helpers
  # ============================================

  defp handle_loaded_content(socket, type, user_id, content, provider) do
    if Access.can_play_global_content?(socket.assigns.current_scope.user, provider) do
      load_authorized_content(socket, type, user_id, content, provider)
    else
      {:ok,
       socket
       |> put_flash(
         :error,
         "Você precisa de uma assinatura ativa ou permissão para assistir conteúdo global."
       )
       |> push_navigate(to: ~p"/plans")}
    end
  end

  defp load_authorized_content(socket, type, user_id, content, provider) do
    case resolve_stream_url(type, content, provider, user_id) do
      {:ok, stream_url} ->
        start_authorized_player(socket, type, user_id, content, provider, stream_url)

      {:error, :not_found} ->
        {:ok,
         socket
         |> put_flash(:error, "Conteúdo não encontrado")
         |> push_navigate(to: ~p"/")}
    end
  end

  defp start_authorized_player(socket, type, user_id, content, provider, stream_url) do
    case reserve_playback_session(socket, type, content, user_id) do
      {:ok, playback_session} ->
        prepare_player_socket(
          socket,
          type,
          user_id,
          content,
          provider,
          stream_url,
          playback_session
        )

      {:error, :concurrent_stream_limit_reached} ->
        {:ok,
         socket
         |> put_flash(:error, "Limite de telas simultâneas atingido para o seu plano.")
         |> push_navigate(to: ~p"/plans?upgrade=screens")}
    end
  end

  defp prepare_player_socket(
         socket,
         type,
         user_id,
         content,
         provider,
         stream_url,
         playback_session
       ) do
    record_watch_history(user_id, type, content)
    prepare_connected_player(socket, type, content, user_id)

    next_episode = load_next_episode(type, content, provider, user_id)

    socket =
      socket
      |> assign(page_title: content_title(content, type))
      |> assign(content_type: safe_content_type(type))
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
      |> assign(next_episode: next_episode)
      |> assign(playback_session: playback_session)

    {:ok, socket}
  end

  defp prepare_connected_player(socket, type, content, user_id) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Streamix.PubSub, "user:#{user_id}:progress")
      prewarm_upstream_redirect(type, content, user_id)
    end
  end

  defp reserve_playback_session(socket, type, content, _user_id) do
    if connected?(socket) do
      Billing.start_playback_session(socket.assigns.current_scope.user, %{
        content_type: type,
        content_id: content.id,
        metadata: %{live_view: "player"}
      })
    else
      {:ok, nil}
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

      :gindex_episode ->
        series_id = socket.assigns.content.season.series_id
        ~p"/gindex/series/#{series_id}"

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

  defp safe_content_type("live_channel"), do: :live_channel
  defp safe_content_type("movie"), do: :movie
  defp safe_content_type("episode"), do: :episode
  defp safe_content_type("gindex"), do: :gindex
  defp safe_content_type("gindex_episode"), do: :gindex_episode
  defp safe_content_type(_), do: :live_channel

  defp safe_streaming_mode("low_latency"), do: :low_latency
  defp safe_streaming_mode("balanced"), do: :balanced
  defp safe_streaming_mode("quality"), do: :quality
  defp safe_streaming_mode("adaptive"), do: :adaptive
  defp safe_streaming_mode(_), do: :balanced
end
