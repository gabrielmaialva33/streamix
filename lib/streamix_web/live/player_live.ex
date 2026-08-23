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

  require Logger

  alias Streamix.{Access, Accounts, Billing}
  import StreamixWeb.PlayerComponents
  import StreamixWeb.PlayerHelpers

  alias Streamix.Iptv
  alias Streamix.Torrent
  alias StreamixWeb.PlayerSourceFailover

  @torrent_peer_target 30

  @impl true
  def mount(%{"type" => type, "id" => id} = params, _session, socket) do
    user_id = socket.assigns.current_scope.user.id
    return_to = safe_return_path(params["return_to"])

    case load_content_preflight(type, id, user_id) do
      {:ok, content, provider} ->
        handle_loaded_content(socket, type, user_id, content, provider, return_to)

      {:error, :not_found} ->
        {:ok,
         socket
         |> put_flash(:error, "Conteúdo não encontrado")
         |> redirect(to: ~p"/")}
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
      {progress_type, progress_id} = progress_ref(type, content)
      Iptv.update_watch_progress(user_id, progress_type, progress_id, current_time, duration)
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

  def handle_event("player_error", params, socket) do
    :telemetry.execute(
      [:streamix, :player, :error],
      %{system_time: System.system_time()},
      %{
        stage: params["stage"] || params["error_name"] || "unknown",
        content_type: socket.assigns[:content_type],
        engine: params["engine"] || "unknown"
      }
    )

    {:noreply, socket}
  end

  def handle_event("request_source_failover", params, socket) do
    position = normalize_failover_position(params["position"])
    reason = normalize_failover_reason(params["reason"])
    request_id = PlayerSourceFailover.normalize_request_id(params["request_id"])

    case PlayerSourceFailover.next(
           socket.assigns.content_type,
           socket.assigns.content,
           socket.assigns.current_scope.user,
           socket.assigns.source_failover_attempted_ids
         ) do
      {:ok, source, attempted_ids} ->
        count = socket.assigns.source_failover_count + 1
        payload = PlayerSourceFailover.payload(source, position, count, request_id)

        :telemetry.execute(
          [:streamix, :player, :source_failover],
          %{count: 1},
          %{
            status: :selected,
            from_content_id: socket.assigns.content.id,
            to_content_id: source.content.id,
            provider_id: source.provider.id,
            reason: reason
          }
        )

        {:noreply,
         socket
         |> assign(
           content: source.content,
           provider: source.provider,
           stream_url: source.stream_url,
           content_type: safe_content_type(source.content_type),
           next_episode:
             load_next_episode(
               source.content_type,
               source.content,
               source.provider,
               socket.assigns.user_id
             ),
           source_failover_attempted_ids: attempted_ids,
           source_failover_count: count
         )
         |> push_event("source_failover", payload)}

      {:error, :no_sources, attempted_ids} ->
        :telemetry.execute(
          [:streamix, :player, :source_failover],
          %{count: 1},
          %{
            status: :unavailable,
            from_content_id: socket.assigns.content.id,
            reason: reason
          }
        )

        {:noreply,
         socket
         |> assign(source_failover_attempted_ids: attempted_ids)
         |> push_event(
           "source_failover_unavailable",
           PlayerSourceFailover.with_request_id(
             %{
               message: "Nenhuma outra fonte está disponível agora.",
               hint: "Tente novamente em alguns instantes ou escolha outra versão nos detalhes."
             },
             request_id
           )
         )}
    end
  end

  def handle_event("reset_source_failover", _params, socket) do
    {:noreply,
     assign(socket,
       source_failover_attempted_ids: MapSet.new([socket.assigns.content.id]),
       source_failover_count: 0
     )}
  end

  def handle_event("player_debug", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("ios_pwa_player_event", params, socket) do
    if Application.get_env(:streamix, :player_lifecycle_logs, false) do
      Logger.debug("ios_pwa_player_event #{params["event"]} content_id=#{params["content_id"]}",
        player_stage: params["event"],
        content_type: params["content_type"],
        source_type: params["source_type"],
        stream_type: params["stream_type"],
        player_engine: params["engine"],
        native_paused: params["paused"],
        native_current_time: params["current_time"]
      )
    end

    {:noreply, socket}
  end

  def handle_event("player_lifecycle", params, socket) do
    if Application.get_env(:streamix, :player_lifecycle_logs, false) do
      Logger.debug("player_lifecycle #{params["stage"]}",
        player_stage: params["stage"],
        player_session_id: params["session_id"],
        player_engine: params["engine"],
        stream_type: params["current_stream_type"],
        content_type: params["content_type"],
        source_type: params["source_type"],
        using_avplayer: params["using_avplayer"],
        native_touch_controls: params["native_touch_controls"],
        native_current_time: params["current_time"],
        native_duration: params["duration"],
        native_ready_state: params["ready_state"],
        native_network_state: params["network_state"],
        native_paused: params["paused"],
        native_seeking: params["seeking"],
        native_autoplay: params["autoplay"],
        native_preload: params["preload"],
        native_buffered_range_count: params["buffered_range_count"],
        native_buffered_ranges: params["buffered_ranges"],
        native_has_current_src: params["has_current_src"],
        native_resume_time: params["resume_time"],
        native_has_audio_issue: params["has_audio_issue"],
        native_error_name: params["error_name"],
        native_error_message: params["error_message"]
      )
    end

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
      {progress_type, progress_id} = progress_ref(type, content)
      Iptv.update_watch_time(user_id, progress_type, progress_id, duration)
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

  def handle_event("adjust_subtitle_offset", %{"delta" => delta}, socket) do
    case Integer.parse(delta) do
      {delta, ""} ->
        user = socket.assigns.current_scope.user
        update_subtitle_offset(socket, user.subtitle_offset_ms + delta)

      _ ->
        {:noreply, put_flash(socket, :error, "Ajuste de legenda inválido")}
    end
  end

  def handle_event("reset_subtitle_offset", _params, socket) do
    update_subtitle_offset(socket, 0)
  end

  def handle_event("toggle_pip", _, socket) do
    {:noreply, push_event(socket, "toggle_pip", %{})}
  end

  def handle_event("close_player", _, socket) do
    back_path = get_back_path(socket)
    {:noreply, redirect(socket, to: back_path)}
  end

  def handle_event("torrent_swarm_ready", _params, socket) do
    {:noreply, maybe_start_torrent_player(socket)}
  end

  def handle_event("torrent_swarm_retry", _params, socket) do
    Torrent.retry(socket.assigns.torrent_info_hash)
    start_torrent_session_task(socket, socket.assigns.content)
    {:noreply, assign(socket, torrent_failure_reason: nil)}
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
  def handle_info({:torrent_session_ready, {:ok, %{file_idx: file_idx}}}, socket) do
    {:noreply, start_torrent_player(socket, file_idx)}
  end

  def handle_info({:torrent_session_ready, {:error, reason}}, socket) do
    {:noreply,
     socket
     |> assign(torrent_failure_reason: reason)
     |> push_event("torrent_swarm_failed", %{reason: inspect(reason)})}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def terminate(_reason, socket) do
    if Map.has_key?(socket.assigns, :user_id) && socket.assigns.user_id do
      Phoenix.PubSub.unsubscribe(Streamix.PubSub, "user:#{socket.assigns.user_id}:progress")
    end

    if Map.has_key?(socket.assigns, :playback_session) do
      Billing.end_playback_session(socket.assigns.playback_session)
    end

    if Map.has_key?(socket.assigns, :torrent_info_hash) do
      Torrent.leave(socket.assigns.torrent_info_hash, self())
    end

    :ok
  end

  # ============================================
  # Render
  # ============================================

  @impl true
  def render(assigns) do
    ~H"""
    <div class="fixed inset-0 h-[100dvh] w-[100dvw] overflow-hidden bg-black">
      <.video_player
        :if={@player_state != :torrent_buffering}
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
        subtitles_enabled={@current_scope.user.subtitles_enabled}
        subtitle_language={@current_scope.user.subtitle_language}
        subtitle_offset_ms={@current_scope.user.subtitle_offset_ms}
        source_failover_enabled={@source_failover_enabled}
      />
      <.torrent_swarm_gate
        :if={@player_state == :torrent_buffering}
        content={@content}
        status_url={@torrent_status_url}
        peer_target={@torrent_peer_target}
        on_close="close_player"
      />
    </div>
    """
  end

  # ============================================
  # Private Helpers
  # ============================================

  defp update_subtitle_offset(socket, offset_ms) do
    user = socket.assigns.current_scope.user

    case Accounts.update_user_settings(user, %{subtitle_offset_ms: offset_ms}) do
      {:ok, updated_user} ->
        {:noreply,
         socket
         |> assign(current_scope: %{socket.assigns.current_scope | user: updated_user})
         |> push_event("subtitle_offset_changed", %{
           offset_ms: updated_user.subtitle_offset_ms
         })}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Não foi possível ajustar a legenda")}
    end
  end

  defp handle_loaded_content(socket, type, user_id, content, provider, return_to) do
    if Access.plays_global_content?(socket.assigns.current_scope.user, provider) do
      load_authorized_content(socket, type, user_id, content, provider, return_to)
    else
      {:ok,
       socket
       |> put_flash(
         :error,
         "Você precisa de uma assinatura ativa ou permissão para assistir conteúdo global."
       )
       |> redirect(to: ~p"/plans")}
    end
  end

  defp load_authorized_content(
         socket,
         "movie",
         user_id,
         content,
         %{provider_type: :torrent},
         return_to
       ) do
    case Torrent.best_stream_for_movie(content.id) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, "Nenhum torrent disponível para este filme")
         |> redirect(to: ~p"/")}

      stream ->
        case load_content_preflight("torrent", stream.id, user_id) do
          {:ok, torrent_content, provider} ->
            load_authorized_content(
              socket,
              "torrent",
              user_id,
              torrent_content,
              provider,
              return_to
            )

          {:error, :not_found} ->
            {:ok,
             socket
             |> put_flash(:error, "Conteúdo não encontrado")
             |> redirect(to: ~p"/")}
        end
    end
  end

  defp load_authorized_content(socket, "torrent" = type, user_id, content, provider, return_to) do
    case reserve_playback_session(socket, type, content, user_id) do
      {:ok, playback_session} ->
        prepare_torrent_gate(
          socket,
          type,
          user_id,
          content,
          provider,
          playback_session,
          return_to
        )

      {:error, :concurrent_stream_limit_reached} ->
        {:ok,
         socket
         |> put_flash(:error, "Limite de telas simultâneas atingido para o seu plano.")
         |> redirect(to: ~p"/plans?upgrade=screens")}
    end
  end

  defp load_authorized_content(socket, type, user_id, content, provider, return_to) do
    case resolve_stream_url(type, content, provider, user_id) do
      {:ok, stream_url} ->
        start_authorized_player(socket, type, user_id, content, provider, stream_url, return_to)

      {:error, :not_found} ->
        {:ok,
         socket
         |> put_flash(:error, "Conteúdo não encontrado")
         |> redirect(to: ~p"/")}
    end
  end

  defp start_authorized_player(socket, type, user_id, content, provider, stream_url, return_to) do
    case reserve_playback_session(socket, type, content, user_id) do
      {:ok, playback_session} ->
        prepare_player_socket(
          socket,
          type,
          user_id,
          content,
          provider,
          stream_url,
          playback_session,
          return_to
        )

      {:error, :concurrent_stream_limit_reached} ->
        {:ok,
         socket
         |> put_flash(:error, "Limite de telas simultâneas atingido para o seu plano.")
         |> redirect(to: ~p"/plans?upgrade=screens")}
    end
  end

  defp prepare_player_socket(
         socket,
         type,
         user_id,
         content,
         provider,
         stream_url,
         playback_session,
         return_to
       ) do
    # Mount runs twice (static HTTP + WS upgrade). Writing watch history on
    # the static pass duplicated every play into the timeline.
    if connected?(socket), do: record_watch_history(user_id, type, content)
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
      |> assign(return_to: return_to)
      |> assign(
        source_failover_enabled: automatic_failover_supported?(type, provider),
        source_failover_attempted_ids: MapSet.new([content.id]),
        source_failover_count: 0
      )

    {:ok, socket}
  end

  defp prepare_connected_player(socket, type, content, user_id) do
    if connected?(socket) do
      topic = "user:#{user_id}:progress"
      # Defensive idempotent subscribe: unsubscribe first so a re-mount on
      # the same LV process (live-redirect within /watch flow) doesn't
      # stack subscriptions and trigger duplicate handle_info callbacks.
      Phoenix.PubSub.unsubscribe(Streamix.PubSub, topic)
      Phoenix.PubSub.subscribe(Streamix.PubSub, topic)
      prewarm_upstream_redirect(type, content, user_id)
    end
  end

  defp prepare_torrent_gate(socket, type, user_id, content, provider, playback_session, return_to) do
    # Mount runs twice — see comment in prepare_player_socket. Same guard.
    if connected?(socket), do: record_watch_history(user_id, type, content)
    start_torrent_session_task(socket, content)

    info_hash = content.torrent_stream.info_hash

    socket =
      socket
      |> assign(page_title: content_title(content, type))
      |> assign(content_type: :torrent)
      |> assign(content: content)
      |> assign(provider: provider)
      |> assign(stream_url: nil)
      |> assign(streaming_mode: default_streaming_mode(type))
      |> assign(player_state: :torrent_buffering)
      |> assign(current_time: 0)
      |> assign(duration: 0)
      |> assign(buffering: true)
      |> assign(pip_active: false)
      |> assign(available_qualities: [])
      |> assign(current_quality: "Automático")
      |> assign(audio_tracks: [])
      |> assign(subtitle_tracks: [])
      |> assign(user_id: user_id)
      |> assign(next_episode: nil)
      |> assign(playback_session: playback_session)
      |> assign(return_to: return_to)
      |> assign(torrent_info_hash: info_hash)
      |> assign(torrent_failure_reason: nil)
      |> assign(torrent_status_url: ~p"/api/stream/torrent/#{info_hash}/status")
      |> assign(torrent_peer_target: @torrent_peer_target)
      |> assign(
        source_failover_enabled: false,
        source_failover_attempted_ids: MapSet.new([content.id]),
        source_failover_count: 0
      )

    {:ok, socket}
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

  defp record_watch_history(user_id, "torrent", content) do
    Iptv.add_to_watch_history(user_id, %{
      content_type: "movie",
      content_id: content.movie_id,
      content_name: content_title(content, "torrent"),
      content_icon: content_icon(content, "torrent")
    })
  end

  defp record_watch_history(user_id, type, content) do
    Iptv.add_to_watch_history(user_id, %{
      content_type: type,
      content_id: content.id,
      content_name: content_title(content, type),
      content_icon: content_icon(content, type)
    })
  end

  defp get_back_path(%{assigns: %{return_to: return_to}}) when is_binary(return_to),
    do: return_to

  defp get_back_path(socket) do
    case socket.assigns.content_type do
      :live_channel ->
        ~p"/providers/#{socket.assigns.provider.id}"

      :movie ->
        ~p"/providers/#{socket.assigns.provider.id}/movies"

      :gindex ->
        ~p"/gindex/movies"

      :torrent ->
        ~p"/browse/movies"

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

  defp safe_return_path(path) when is_binary(path) do
    if String.starts_with?(path, "/") and not String.starts_with?(path, "//") do
      path
    end
  end

  defp safe_return_path(_), do: nil

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
  defp safe_content_type("torrent"), do: :torrent
  defp safe_content_type(_), do: :live_channel

  defp safe_streaming_mode("low_latency"), do: :low_latency
  defp safe_streaming_mode("balanced"), do: :balanced
  defp safe_streaming_mode("quality"), do: :quality
  defp safe_streaming_mode("adaptive"), do: :adaptive
  defp safe_streaming_mode(_), do: :balanced

  defp normalize_failover_position(value) when is_integer(value) and value >= 0, do: value * 1.0

  defp normalize_failover_position(value) when is_float(value) and value >= 0,
    do: value

  defp normalize_failover_position(value) when is_binary(value) do
    case Float.parse(value) do
      {position, ""} when position >= 0 -> position
      _ -> 0.0
    end
  end

  defp normalize_failover_position(_value), do: 0.0

  defp normalize_failover_reason(reason) when is_binary(reason) do
    reason
    |> String.trim()
    |> String.slice(0, 160)
  end

  defp normalize_failover_reason(_reason), do: "unknown"

  defp start_torrent_session_task(socket, content) do
    if connected?(socket) do
      live_view_pid = self()
      stream = content.torrent_stream

      # Task.Supervisor.start_child instead of bare Task.start so a crash
      # in Torrent.start_or_join surfaces in the supervisor tree
      # (and shows up in observers) rather than vanishing silently.
      Task.Supervisor.start_child(Streamix.TaskSupervisor, fn ->
        result = Torrent.start_or_join(stream.info_hash, stream.magnet_uri, live_view_pid)
        send(live_view_pid, {:torrent_session_ready, result})
      end)
    end
  end

  defp maybe_start_torrent_player(%{assigns: %{player_state: :torrent_buffering}} = socket) do
    start_torrent_player(socket, nil)
  end

  defp maybe_start_torrent_player(socket), do: socket

  defp start_torrent_player(socket, file_idx) do
    info_hash = socket.assigns.torrent_info_hash
    stream_url = torrent_stream_url(info_hash, file_idx)

    socket
    |> assign(stream_url: stream_url)
    |> assign(player_state: :loading)
    |> assign(buffering: false)
  end

  defp torrent_stream_url(info_hash, nil) do
    "/api/stream/torrent/#{info_hash}"
  end

  defp torrent_stream_url(info_hash, file_idx) do
    "/api/stream/torrent/#{info_hash}/#{file_idx}"
  end

  defp progress_ref("torrent", %{movie_id: movie_id}) when is_integer(movie_id),
    do: {"movie", movie_id}

  defp progress_ref(type, %{id: id}), do: {type, id}
end
