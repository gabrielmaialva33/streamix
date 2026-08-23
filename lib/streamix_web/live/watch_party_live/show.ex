defmodule StreamixWeb.WatchPartyLive.Show do
  @moduledoc """
  Connected Watch Party player with durable sync, billing enforcement and chat.
  """
  use StreamixWeb, :live_view

  import StreamixWeb.PlayerComponents
  import StreamixWeb.PlayerHelpers
  import StreamixWeb.WatchPartyComponents

  alias Streamix.{Accounts, Billing, Iptv, WatchParty}
  alias StreamixWeb.{PlayerSourceFailover, Presence}
  alias StreamixWeb.WatchPartyLive.Status

  require Logger

  @presence_topic_prefix "watch_party:presence:"
  @message_window 200
  @minimum_beacon_interval_ms 250
  @minimum_buffering_transition_ms 100
  @max_position_seconds 31_536_000
  @sync_states ~w(connecting synced correcting buffering host_offline disconnected)

  @impl true
  def mount(%{"invite_code" => invite_code}, _session, socket) do
    user_id = socket.assigns.current_scope.user.id

    with %{} = room <- WatchParty.get_room_by_invite_with_content(invite_code),
         :ok <- WatchParty.authorize_room_user(room, user_id),
         {:ok, source_type, source_id} <- room_source_ref(room),
         {:ok, content, provider} <-
           load_content_preflight(source_type, to_string(source_id), user_id) do
      build_room_socket(socket, room, source_type, content, provider)
    else
      nil -> unavailable_room(socket)
      {:error, :content_not_entitled} -> content_not_entitled(socket)
      {:error, _reason} -> content_unavailable(socket)
    end
  end

  defp build_room_socket(socket, room, source_type, content, provider) do
    user = socket.assigns.current_scope.user
    user_id = user.id
    is_host = room.host_user_id == user_id
    messages = WatchParty.list_messages(room.id, limit: 50)
    presences = Presence.list(presence_topic(room.id))
    playback_state = persisted_playback(room)

    socket =
      socket
      |> assign(
        page_title: "Watch Party — #{content_title(content, source_type)}",
        current_path: "/party/#{room.invite_code}/watch",
        room: room,
        content: content,
        source_type: source_type,
        content_type: safe_content_type(source_type),
        provider: provider,
        stream_url: nil,
        streaming_mode: default_streaming_mode(source_type),
        is_host: is_host,
        user_id: user_id,
        playback_state: playback_state,
        playback_session: nil,
        connection_id: nil,
        joined: false,
        presences: presences,
        host_status: if(host_online?(presences), do: :online, else: :offline),
        sync_status: if(is_host, do: "synced", else: "connecting"),
        sync_drift_ms: nil,
        chat_open: false,
        chat_error: nil,
        unread_messages: 0,
        message_input: "",
        message_ids: Enum.map(messages, & &1.id),
        next_episode: nil,
        current_time: 0,
        duration: 0,
        buffering: false,
        last_beacon_at: nil,
        last_beacon_buffering: false,
        last_buffering_transition_at: nil,
        source_failover_enabled: is_host and automatic_failover_supported?(source_type, provider),
        source_failover_attempted_ids: MapSet.new([content.id]),
        source_failover_count: 0,
        pending_source_failover: nil
      )
      |> stream(:messages, messages)

    if connected?(socket) do
      connect_room(socket)
    else
      {:ok, socket}
    end
  end

  defp connect_room(socket) do
    room = socket.assigns.room
    connection_id = connection_id()

    :ok = Phoenix.PubSub.subscribe(Streamix.PubSub, WatchParty.topic(room.id))
    :ok = Phoenix.PubSub.subscribe(Streamix.PubSub, presence_topic(room.id))

    case start_playback_session(socket, connection_id) do
      {:ok, playback_session} ->
        resolve_connected_stream(socket, connection_id, playback_session)

      {:error, :concurrent_stream_limit_reached} ->
        {:ok,
         socket
         |> put_flash(:error, "Limite de telas simultâneas atingido para o seu plano.")
         |> redirect(to: ~p"/plans?upgrade=screens")}

      {:error, reason} ->
        Logger.warning("Watch Party playback reservation failed: #{inspect(reason)}")

        {:ok,
         socket
         |> put_flash(:error, "Não foi possível reservar uma tela para esta sala")
         |> redirect(to: ~p"/party")}
    end
  end

  defp resolve_connected_stream(socket, connection_id, playback_session) do
    user = socket.assigns.current_scope.user

    case resolve_stream_url(
           socket.assigns.source_type,
           socket.assigns.content,
           socket.assigns.provider,
           user.id
         ) do
      {:ok, stream_url} ->
        join_connected_room(socket, connection_id, playback_session, stream_url)

      {:error, reason} ->
        release_playback_session(playback_session)
        Logger.warning("Watch Party stream resolution failed: #{inspect(reason)}")

        {:ok,
         socket
         |> put_flash(:error, "Não foi possível preparar a reprodução desta sala")
         |> redirect(to: ~p"/party")}
    end
  end

  defp join_connected_room(socket, connection_id, playback_session, stream_url) do
    room = socket.assigns.room
    user = socket.assigns.current_scope.user

    case WatchParty.join_room(room.id, user.id, connection_id) do
      {:ok, _participant} ->
        track_connected_presence(socket, connection_id, playback_session, stream_url)

      {:error, :room_full} ->
        release_playback_session(playback_session)

        {:ok,
         socket
         |> put_flash(:error, "A Watch Party está cheia")
         |> redirect(to: ~p"/party")}

      {:error, :content_not_entitled} ->
        release_playback_session(playback_session)
        content_not_entitled(socket)

      {:error, reason} ->
        release_playback_session(playback_session)
        Logger.warning("Watch Party join failed: #{inspect(reason)}")

        {:ok,
         socket
         |> put_flash(:error, "Não foi possível entrar na Watch Party")
         |> redirect(to: ~p"/party")}
    end
  end

  defp track_connected_presence(socket, connection_id, playback_session, stream_url) do
    room = socket.assigns.room
    user = socket.assigns.current_scope.user

    case Presence.track(self(), presence_topic(room.id), to_string(user.id), %{
           user_id: user.id,
           label: WatchParty.participant_label(room.id, user.id),
           is_host: socket.assigns.is_host,
           joined_at: System.system_time(:second),
           connection_id: connection_id
         }) do
      {:ok, _presence_ref} ->
        prewarm_upstream_redirect(socket.assigns.source_type, socket.assigns.content, user.id)
        record_watch_history(socket.assigns.source_type, socket.assigns.content, user.id)

        playback_state = current_playback(room)
        presences = Presence.list(presence_topic(room.id))

        next_episode =
          if socket.assigns.is_host do
            load_next_episode(
              socket.assigns.source_type,
              socket.assigns.content,
              socket.assigns.provider,
              user.id
            )
          end

        {:ok,
         assign(socket,
           playback_session: playback_session,
           connection_id: connection_id,
           joined: true,
           stream_url: stream_url,
           next_episode: next_episode,
           playback_state: playback_state,
           presences: presences,
           host_status: if(host_online?(presences), do: :online, else: :offline)
         )}

      {:error, reason} ->
        WatchParty.leave_room(room.id, user.id, connection_id)
        release_playback_session(playback_session)
        Logger.warning("Watch Party presence tracking failed: #{inspect(reason)}")

        {:ok,
         socket
         |> put_flash(:error, "Não foi possível conectar à presença da sala")
         |> redirect(to: ~p"/party")}
    end
  end

  # --- Watch Party protocol ---

  @impl true
  def handle_event("wp_play", %{"position" => position}, socket),
    do: dispatch_playback(socket, "play", position)

  def handle_event("wp_pause", %{"position" => position}, socket),
    do: dispatch_playback(socket, "pause", position)

  def handle_event("wp_seek", %{"position" => position}, socket),
    do: dispatch_playback(socket, "seek", position)

  def handle_event("wp_sync_beacon", params, socket) do
    now = System.monotonic_time(:millisecond)

    with true <- socket.assigns.joined,
         {:ok, position} <- normalize_position(params["position"]),
         {:ok, state} <- normalize_playback_state(params["state"]),
         {:ok, buffering} <- normalize_boolean(params["buffering"]),
         transition? = buffering != socket.assigns.last_beacon_buffering,
         true <- beacon_allowed?(socket, params, now, transition?) do
      WatchParty.send_sync_beacon(
        socket.assigns.room.id,
        socket.assigns.user_id,
        socket.assigns.connection_id,
        position,
        state,
        buffering,
        normalize_client_time(params["client_time"])
      )

      {:noreply,
       assign(socket,
         last_beacon_at: now,
         last_beacon_buffering: buffering,
         last_buffering_transition_at:
           if(transition?, do: now, else: socket.assigns.last_buffering_transition_at)
       )}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("wp_clock_ping", %{"id" => id}, socket) do
    case normalize_clock_id(id) do
      {:ok, normalized_id} ->
        {:noreply,
         push_event(socket, "wp_clock_pong", %{
           id: normalized_id,
           server_time: System.system_time(:millisecond)
         })}

      :error ->
        {:noreply, socket}
    end
  end

  def handle_event("wp_request_sync", _params, socket) do
    case WatchParty.get_playback_state(socket.assigns.room.id) do
      {:ok, playback, _host_id} ->
        command = sync_payload(playback)

        {:noreply,
         socket
         |> assign_server_playback(command)
         |> push_event("wp_sync_command", command)}

      _ ->
        {:noreply, assign(socket, sync_status: "disconnected")}
    end
  end

  def handle_event("wp_sync_status", params, socket) do
    status = params["status"]
    drift = normalize_optional_integer(params["drift_ms"])

    if status in @sync_states do
      {:noreply, assign(socket, sync_status: status, sync_drift_ms: drift)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("wp_next_episode", _params, socket) do
    if socket.assigns.is_host and socket.assigns.next_episode do
      next = socket.assigns.next_episode
      source_type = to_string(next.type)

      with {:ok, catalog_item_id} <- resolve_catalog_item_id(source_type, %{id: next.id}),
           {:ok, _version} <-
             WatchParty.change_content(
               socket.assigns.room.id,
               socket.assigns.user_id,
               socket.assigns.connection_id,
               %{
                 catalog_item_id: catalog_item_id,
                 source_type: source_type,
                 source_id: next.id
               }
             ) do
        {:noreply, assign(socket, next_episode: nil)}
      else
        _ ->
          {:noreply, put_flash(socket, :error, "Não foi possível abrir o próximo episódio")}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("wp_leave", _params, socket) do
    socket = release_room_connection(socket)
    {:noreply, redirect(socket, to: ~p"/")}
  end

  def handle_event("wp_end_party", _params, socket) do
    if socket.assigns.is_host and socket.assigns.joined do
      WatchParty.end_room(
        socket.assigns.room.id,
        socket.assigns.user_id,
        socket.assigns.connection_id
      )
    end

    socket = release_local_playback_session(socket)
    {:noreply, redirect(socket, to: ~p"/")}
  end

  # --- Chat ---

  def handle_event("toggle_chat", _params, socket) do
    opening? = not socket.assigns.chat_open

    socket =
      assign(socket,
        chat_open: opening?,
        unread_messages: if(opening?, do: 0, else: socket.assigns.unread_messages),
        chat_error: nil
      )

    {:noreply, if(opening?, do: push_event(socket, "wp_chat_opened", %{}), else: socket)}
  end

  def handle_event("send_message", %{"message" => content}, socket) do
    content = String.trim(content || "")

    cond do
      content == "" ->
        {:noreply, socket}

      byte_size(content) > 500 ->
        {:noreply, assign(socket, chat_error: "A mensagem pode ter no máximo 500 caracteres.")}

      true ->
        send_chat_message(socket, content)
    end
  end

  def handle_event("send_message", _params, socket), do: {:noreply, socket}

  def handle_event("send_reaction", %{"emoji" => emoji}, socket) do
    key = "party_reaction:#{socket.assigns.room.id}:#{socket.assigns.user_id}"

    case Streamix.RateLimit.hit(key, 5_000, 8) do
      {:allow, _remaining} ->
        WatchParty.send_reaction(socket.assigns.room.id, socket.assigns.user_id, emoji)
        {:noreply, socket}

      {:deny, _retry_after} ->
        {:noreply, assign(socket, chat_error: "Reações rápidas demais. Aguarde um instante.")}
    end
  end

  # --- Shared player events ---

  def handle_event(
        "progress_update",
        %{"current_time" => current_time, "duration" => duration},
        socket
      ) do
    with {:ok, current_time} <- normalize_position(current_time),
         {:ok, duration} <- normalize_duration(duration) do
      if socket.assigns.content_type not in [:live, :live_channel] do
        {type, id} = progress_ref(socket.assigns.source_type, socket.assigns.content)
        Iptv.update_watch_progress(socket.assigns.user_id, type, id, current_time, duration)
      end

      Billing.touch_playback_session(socket.assigns.playback_session)
      {:noreply, assign(socket, current_time: current_time, duration: duration)}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("update_watch_time", %{"duration" => duration}, socket) do
    case normalize_duration(duration) do
      {:ok, duration} ->
        {type, id} = progress_ref(socket.assigns.source_type, socket.assigns.content)
        Iptv.update_watch_time(socket.assigns.user_id, type, id, duration)
        Billing.touch_playback_session(socket.assigns.playback_session)
        {:noreply, socket}

      :error ->
        {:noreply, socket}
    end
  end

  def handle_event("player_initializing", _params, socket) do
    Billing.touch_playback_session(socket.assigns.playback_session)
    {:noreply, socket}
  end

  def handle_event("player_error", params, socket) do
    :telemetry.execute(
      [:streamix, :watch_party, :player_error],
      %{count: 1},
      %{
        room_id: socket.assigns.room.id,
        stage: params["stage"] || params["error_name"] || "unknown",
        engine: params["engine"] || "unknown",
        role: if(socket.assigns.is_host, do: :host, else: :viewer)
      }
    )

    {:noreply, socket}
  end

  def handle_event("request_source_failover", params, socket) do
    request_id = PlayerSourceFailover.normalize_request_id(params["request_id"])

    with true <-
           socket.assigns.is_host and socket.assigns.joined and
             socket.assigns.source_failover_enabled,
         {:ok, position} <- normalize_position(params["position"]),
         {:ok, source, attempted_ids} <-
           PlayerSourceFailover.next(
             socket.assigns.source_type,
             socket.assigns.content,
             socket.assigns.current_scope.user,
             socket.assigns.source_failover_attempted_ids
           ),
         {:ok, catalog_item_id} <- resolve_catalog_item_id(source.content_type, source.content),
         count = socket.assigns.source_failover_count + 1,
         payload = PlayerSourceFailover.payload(source, position, count, request_id),
         {:ok, version} <-
           WatchParty.change_content(
             socket.assigns.room.id,
             socket.assigns.user_id,
             socket.assigns.connection_id,
             %{
               catalog_item_id: catalog_item_id,
               source_type: source.content_type,
               source_id: source.content.id,
               position: position
             }
           ) do
      :telemetry.execute(
        [:streamix, :watch_party, :source_failover],
        %{count: 1},
        %{
          room_id: socket.assigns.room.id,
          from_content_id: socket.assigns.content.id,
          to_content_id: source.content.id,
          provider_id: source.provider.id,
          reason: normalize_failover_reason(params["reason"]),
          status: :selected
        }
      )

      {:noreply,
       assign(socket,
         source_failover_attempted_ids: attempted_ids,
         source_failover_count: count,
         pending_source_failover: %{version: version, source: source, payload: payload}
       )}
    else
      {:error, :no_sources, attempted_ids} ->
        source_failover_unavailable(socket, attempted_ids, params["reason"], request_id)

      _reason ->
        source_failover_unavailable(
          socket,
          socket.assigns.source_failover_attempted_ids,
          params["reason"],
          request_id
        )
    end
  end

  def handle_event("reset_source_failover", _params, socket) do
    if socket.assigns.is_host do
      {:noreply,
       assign(socket,
         source_failover_attempted_ids: MapSet.new([socket.assigns.content.id]),
         source_failover_count: 0,
         pending_source_failover: nil
       )}
    else
      {:noreply, socket}
    end
  end

  def handle_event("buffering", %{"buffering" => buffering}, socket)
      when is_boolean(buffering) do
    socket = assign(socket, buffering: buffering)

    if socket.assigns.is_host and socket.assigns.joined do
      sync_host_buffering(socket, buffering)
    else
      {:noreply, socket}
    end
  end

  def handle_event("buffering", _params, socket), do: {:noreply, socket}

  def handle_event("streaming_mode_changed", %{"mode" => mode}, socket) do
    {:noreply, assign(socket, streaming_mode: safe_streaming_mode(mode))}
  end

  def handle_event("set_quality", %{"level" => level}, socket),
    do: {:noreply, push_event(socket, "set_quality", %{level: level})}

  def handle_event("set_audio_track", %{"track" => track}, socket),
    do: {:noreply, push_event(socket, "set_audio_track", %{track: track})}

  def handle_event("set_subtitle_track", %{"track" => track}, socket),
    do: {:noreply, push_event(socket, "set_subtitle_track", %{track: track})}

  def handle_event("adjust_subtitle_offset", %{"delta" => delta}, socket) do
    case Integer.parse(to_string(delta)) do
      {delta, ""} ->
        update_subtitle_offset(
          socket,
          socket.assigns.current_scope.user.subtitle_offset_ms + delta
        )

      _ ->
        {:noreply, put_flash(socket, :error, "Ajuste de legenda inválido")}
    end
  end

  def handle_event("reset_subtitle_offset", _params, socket),
    do: update_subtitle_offset(socket, 0)

  def handle_event("toggle_pip", _params, socket),
    do: {:noreply, push_event(socket, "toggle_pip", %{})}

  def handle_event("close_player", _params, socket) do
    socket = release_room_connection(socket)
    {:noreply, redirect(socket, to: ~p"/")}
  end

  # Browser-only events that don't need server state.
  def handle_event(event, _params, socket)
      when event in [
             "player_lifecycle",
             "ios_pwa_player_event",
             "qualities_available",
             "quality_changed",
             "audio_tracks_available",
             "subtitle_tracks_available",
             "pip_toggled",
             "device_diagnostics",
             "player_debug",
             "codec_abr_suggestion",
             "diagnostic_suggestion",
             "quality_switched",
             "playback_rate_changed",
             "duration_available",
             "mute_toggled",
             "volume_changed",
             "audio_track_changed",
             "subtitle_track_changed",
             "pip_error",
             "request_token_refresh",
             "avplayer_preference_changed"
           ] do
    {:noreply, socket}
  end

  def handle_event(event, _params, socket) do
    Logger.debug("Ignored unknown Watch Party event #{inspect(event)}")
    {:noreply, socket}
  end

  # --- PubSub ---

  @impl true
  def handle_info({:sync_command, command}, socket) do
    {:noreply,
     socket
     |> assign_server_playback(command)
     |> push_event("wp_sync_command", command)}
  end

  def handle_info({:resync_user, %{target_user_id: user_id} = command}, socket)
      when user_id == socket.assigns.user_id do
    {:noreply,
     socket
     |> assign_server_playback(command)
     |> push_event("wp_sync_command", command)}
  end

  def handle_info({:resync_user, _command}, socket), do: {:noreply, socket}

  def handle_info({:new_message, message}, socket) do
    socket = insert_message(socket, message)
    {:noreply, push_event(socket, "wp_chat_message", %{message_id: message.id})}
  end

  def handle_info({:reaction, reaction}, socket) do
    {:noreply, push_event(socket, "wp_floating_reaction", reaction)}
  end

  def handle_info({:participant_joined, _user_id}, socket),
    do: {:noreply, update_presences(socket)}

  def handle_info({:participant_left, _user_id}, socket),
    do: {:noreply, update_presences(socket)}

  def handle_info({:host_status, status}, socket) when status in [:online, :offline] do
    {:noreply,
     socket
     |> assign(host_status: status)
     |> push_event("wp_host_status", %{status: Atom.to_string(status)})}
  end

  def handle_info(
        {:content_changed, %{version: version} = change},
        %{assigns: %{pending_source_failover: %{version: version} = pending}} = socket
      ) do
    {:noreply, apply_pending_source_failover(socket, pending, change)}
  end

  def handle_info({:content_changed, %{version: version}}, socket) do
    {:noreply,
     push_navigate(socket,
       to: ~p"/party/#{socket.assigns.room.invite_code}/watch?v=#{version}"
     )}
  end

  def handle_info({:room_ended, reason}, socket), do: room_ended(socket, reason)
  def handle_info(:room_ended, socket), do: room_ended(socket, "host_ended")

  def handle_info(%Phoenix.Socket.Broadcast{event: "presence_diff"}, socket) do
    {:noreply, update_presences(socket)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def terminate(_reason, socket) do
    if socket.assigns[:joined] and socket.assigns[:connection_id] do
      WatchParty.leave_room(
        socket.assigns.room.id,
        socket.assigns.user_id,
        socket.assigns.connection_id
      )
    end

    Billing.end_playback_session(socket.assigns[:playback_session])
    :ok
  rescue
    _error -> :ok
  end

  # --- Private helpers ---

  defp apply_pending_source_failover(socket, pending, change) do
    source = pending.source
    position = Map.get(change, :position, pending.payload.resume_time)
    version = Map.fetch!(change, :version)

    room = %{
      socket.assigns.room
      | catalog_item_id: Map.get(change, :catalog_item_id, socket.assigns.room.catalog_item_id),
        source_type: source.content_type,
        source_id: source.content.id,
        playback_state: "paused",
        playback_position: position,
        playback_buffering: false,
        playback_version: version
    }

    playback_state = %{
      state: :paused,
      position: position,
      host_buffering: false,
      version: version,
      server_time: System.system_time(:millisecond)
    }

    socket
    |> assign(
      page_title: "Watch Party — #{content_title(source.content, source.content_type)}",
      room: room,
      content: source.content,
      source_type: source.content_type,
      content_type: safe_content_type(source.content_type),
      provider: source.provider,
      stream_url: source.stream_url,
      next_episode:
        load_next_episode(
          source.content_type,
          source.content,
          source.provider,
          socket.assigns.user_id
        ),
      playback_state: playback_state,
      current_time: position,
      buffering: false,
      pending_source_failover: nil
    )
    |> push_event("source_failover", pending.payload)
  end

  defp source_failover_unavailable(socket, attempted_ids, reason, request_id) do
    :telemetry.execute(
      [:streamix, :watch_party, :source_failover],
      %{count: 1},
      %{
        room_id: socket.assigns.room.id,
        from_content_id: socket.assigns.content.id,
        reason: normalize_failover_reason(reason),
        status: :unavailable
      }
    )

    {:noreply,
     socket
     |> assign(
       source_failover_attempted_ids: attempted_ids,
       pending_source_failover: nil
     )
     |> push_event(
       "source_failover_unavailable",
       PlayerSourceFailover.with_request_id(
         %{
           message: "Nenhuma outra fonte está disponível agora.",
           hint:
             "Tente novamente em alguns instantes ou encerre a sala para escolher outra versão."
         },
         request_id
       )
     )}
  end

  defp dispatch_playback(socket, action, raw_position) do
    with true <- socket.assigns.is_host and socket.assigns.joined,
         {:ok, position} <- normalize_position(raw_position),
         :ok <-
           WatchParty.playback_action(
             socket.assigns.room.id,
             socket.assigns.user_id,
             socket.assigns.connection_id,
             %{"action" => action, "position" => position}
           ) do
      {:noreply, socket}
    else
      false ->
        {:noreply, put_flash(socket, :error, "Apenas o anfitrião pode controlar o player.")}

      {:error, :invalid_playback_action} ->
        {:noreply, socket}

      {:error, _reason} ->
        {:noreply, assign(socket, sync_status: "disconnected")}

      :error ->
        {:noreply, socket}
    end
  end

  defp send_chat_message(socket, content) do
    key = "party_message:#{socket.assigns.room.id}:#{socket.assigns.user_id}"

    case Streamix.RateLimit.hit(key, 10_000, 10) do
      {:allow, _remaining} ->
        case WatchParty.send_message(socket.assigns.room.id, socket.assigns.user_id, content) do
          {:ok, _message} ->
            {:noreply, assign(socket, message_input: "", chat_error: nil)}

          {:error, _reason} ->
            {:noreply, assign(socket, chat_error: "Não foi possível enviar a mensagem.")}
        end

      {:deny, _retry_after} ->
        {:noreply, assign(socket, chat_error: "Muitas mensagens. Aguarde alguns segundos.")}
    end
  end

  defp insert_message(socket, message) do
    message_ids = socket.assigns.message_ids ++ [message.id]
    socket = stream_insert(socket, :messages, message)

    {socket, message_ids} =
      if length(message_ids) > @message_window do
        [oldest_id | remaining_ids] = message_ids
        {stream_delete_by_dom_id(socket, :messages, "messages-#{oldest_id}"), remaining_ids}
      else
        {socket, message_ids}
      end

    unread_messages =
      if socket.assigns.chat_open or message.user_id == socket.assigns.user_id do
        socket.assigns.unread_messages
      else
        socket.assigns.unread_messages + 1
      end

    assign(socket, message_ids: message_ids, unread_messages: unread_messages)
  end

  defp update_presences(socket) do
    presences = Presence.list(presence_topic(socket.assigns.room.id))

    assign(socket,
      presences: presences,
      host_status: if(host_online?(presences), do: :online, else: :offline)
    )
  end

  defp host_online?(presences) do
    Enum.any?(presences, fn {_key, %{metas: metas}} ->
      Enum.any?(metas, &(Map.get(&1, :is_host) == true))
    end)
  end

  defp room_ended(socket, reason) do
    message =
      case reason do
        "host_disconnected" -> "A sala foi encerrada porque o anfitrião não retornou."
        "idle_timeout" -> "A Watch Party foi encerrada por inatividade."
        "content_removed" -> "O conteúdo desta Watch Party não está mais disponível."
        _ -> "A Watch Party foi encerrada."
      end

    {:noreply,
     socket
     |> assign(joined: false)
     |> put_flash(:info, message)
     |> redirect(to: ~p"/")}
  end

  defp start_playback_session(socket, connection_id) do
    Billing.start_playback_session(socket.assigns.current_scope.user, %{
      content_type: socket.assigns.source_type,
      content_id: socket.assigns.content.id,
      metadata: %{
        live_view: "watch_party",
        room_id: socket.assigns.room.id,
        connection_id: connection_id
      }
    })
  end

  defp release_room_connection(socket) do
    if socket.assigns.joined and socket.assigns.connection_id do
      WatchParty.leave_room(
        socket.assigns.room.id,
        socket.assigns.user_id,
        socket.assigns.connection_id
      )
    end

    socket
    |> assign(joined: false, connection_id: nil)
    |> release_local_playback_session()
  end

  defp release_local_playback_session(socket) do
    release_playback_session(socket.assigns[:playback_session])
    assign(socket, playback_session: nil)
  end

  defp release_playback_session(session), do: Billing.end_playback_session(session)

  defp record_watch_history("torrent", content, user_id) do
    Iptv.add_to_watch_history(user_id, %{
      content_type: "movie",
      content_id: content.movie_id,
      content_name: content_title(content, "torrent"),
      content_icon: content_icon(content, "torrent")
    })
  end

  defp record_watch_history(source_type, content, user_id) do
    Iptv.add_to_watch_history(user_id, %{
      content_type: canonical_content_type(source_type),
      content_id: content.id,
      content_name: content_title(content, source_type),
      content_icon: content_icon(content, source_type)
    })
  end

  defp progress_ref("torrent", %{movie_id: movie_id}), do: {"movie", movie_id}
  defp progress_ref(source_type, %{id: id}), do: {canonical_content_type(source_type), id}

  defp update_subtitle_offset(socket, offset_ms) do
    user = socket.assigns.current_scope.user

    case Accounts.update_user_settings(user, %{subtitle_offset_ms: offset_ms}) do
      {:ok, updated_user} ->
        {:noreply,
         socket
         |> assign(current_scope: %{socket.assigns.current_scope | user: updated_user})
         |> push_event("subtitle_offset_changed", %{offset_ms: updated_user.subtitle_offset_ms})}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Não foi possível ajustar a legenda")}
    end
  end

  defp current_playback(room) do
    case WatchParty.get_playback_state(room.id) do
      {:ok, playback, _host_id} -> playback
      _ -> persisted_playback(room)
    end
  end

  defp persisted_playback(room) do
    %{
      state: if(room.playback_state == "playing", do: :playing, else: :paused),
      position: room.playback_position || 0.0,
      host_buffering: room.playback_buffering == true,
      version: room.playback_version || 0
    }
  end

  defp sync_payload(playback) do
    %{
      type: "sync",
      state: Atom.to_string(playback.state),
      position: playback.position,
      host_buffering: Map.get(playback, :host_buffering, false),
      sequence: Map.get(playback, :version, 0),
      server_time: System.system_time(:millisecond)
    }
  end

  defp assign_server_playback(socket, command) when is_map(command) do
    with {:ok, position} <- normalize_position(command[:position] || command["position"]),
         {:ok, state} <- normalize_playback_state(command[:state] || command["state"]),
         {:ok, buffering} <-
           normalize_boolean(command[:host_buffering] || command["host_buffering"] || false) do
      sequence = normalize_optional_integer(command[:sequence] || command["sequence"]) || 0
      server_time = normalize_optional_integer(command[:server_time] || command["server_time"])

      assign(socket,
        playback_state: %{
          state: String.to_existing_atom(state),
          position: position,
          host_buffering: buffering,
          version: sequence,
          server_time: server_time
        }
      )
    else
      _ -> socket
    end
  end

  defp assign_server_playback(socket, _command), do: socket

  defp room_source_ref(room) do
    content = Iptv.catalog_item_content(room.catalog_item)

    cond do
      is_binary(room.source_type) and is_integer(room.source_id) and room.source_id > 0 ->
        {:ok, room.source_type, room.source_id}

      is_map(content) and is_integer(content.id) ->
        {:ok, room.catalog_item.content_type, content.id}

      true ->
        {:error, :content_not_available}
    end
  end

  defp sync_host_buffering(socket, buffering) do
    case WatchParty.get_playback_state(socket.assigns.room.id) do
      {:ok, playback, host_user_id} when host_user_id == socket.assigns.user_id ->
        WatchParty.send_sync_beacon(
          socket.assigns.room.id,
          socket.assigns.user_id,
          socket.assigns.connection_id,
          playback.position,
          Atom.to_string(playback.state),
          buffering,
          System.system_time(:millisecond)
        )

        now = System.monotonic_time(:millisecond)

        {:noreply,
         assign(socket,
           last_beacon_at: now,
           last_beacon_buffering: buffering,
           last_buffering_transition_at: now
         )}

      _other ->
        {:noreply, socket}
    end
  end

  defp connection_id do
    "party:" <> Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
  end

  defp presence_topic(room_id), do: @presence_topic_prefix <> to_string(room_id)

  defp beacon_allowed?(socket, params, now, transition?) do
    normal_ready? =
      is_nil(socket.assigns.last_beacon_at) or
        now - socket.assigns.last_beacon_at >= @minimum_beacon_interval_ms

    transition_ready? =
      is_nil(socket.assigns.last_buffering_transition_at) or
        now - socket.assigns.last_buffering_transition_at >= @minimum_buffering_transition_ms

    normal_ready? or (params["urgent"] == true and transition? and transition_ready?)
  end

  defp normalize_position(value) when is_integer(value), do: normalize_position(value * 1.0)

  defp normalize_position(value)
       when is_float(value) and value >= 0 and value <= @max_position_seconds,
       do: {:ok, value}

  defp normalize_position(value) when is_binary(value) do
    case Float.parse(value) do
      {number, ""} -> normalize_position(number)
      _ -> :error
    end
  end

  defp normalize_position(_value), do: :error

  defp normalize_duration(value) do
    case normalize_position(value) do
      {:ok, duration} when duration > 0 -> {:ok, duration}
      _ -> :error
    end
  end

  defp normalize_playback_state(state) when state in ["playing", "paused"], do: {:ok, state}
  defp normalize_playback_state(_state), do: :error

  defp normalize_boolean(value) when is_boolean(value), do: {:ok, value}
  defp normalize_boolean(_value), do: :error

  defp normalize_client_time(value) when is_integer(value) and value >= 0, do: value
  defp normalize_client_time(value) when is_float(value) and value >= 0, do: trunc(value)
  defp normalize_client_time(_value), do: 0

  defp normalize_clock_id(value) when is_integer(value) and value >= 0, do: {:ok, value}

  defp normalize_clock_id(value) when is_binary(value) and byte_size(value) <= 64,
    do: {:ok, value}

  defp normalize_clock_id(_value), do: :error

  defp normalize_optional_integer(value) when is_integer(value), do: value
  defp normalize_optional_integer(value) when is_float(value), do: trunc(value)
  defp normalize_optional_integer(_value), do: nil

  defp normalize_failover_reason(reason) when is_binary(reason) do
    reason
    |> String.trim()
    |> String.slice(0, 160)
  end

  defp normalize_failover_reason(_reason), do: "unknown"

  defp safe_content_type("live_channel"), do: :live_channel
  defp safe_content_type("movie"), do: :movie
  defp safe_content_type("episode"), do: :episode
  defp safe_content_type("gindex"), do: :gindex
  defp safe_content_type("gindex_episode"), do: :gindex_episode
  defp safe_content_type("torrent"), do: :torrent
  defp safe_content_type(_type), do: :movie

  defp safe_streaming_mode("low_latency"), do: :low_latency
  defp safe_streaming_mode("balanced"), do: :balanced
  defp safe_streaming_mode("quality"), do: :quality
  defp safe_streaming_mode("adaptive"), do: :adaptive
  defp safe_streaming_mode(_mode), do: :balanced

  defp unavailable_room(socket) do
    {:ok,
     socket
     |> put_flash(:error, "Watch Party não encontrada ou já encerrada")
     |> redirect(to: ~p"/party")}
  end

  defp content_not_entitled(socket) do
    {:ok,
     socket
     |> put_flash(:error, "Seu plano não permite reproduzir o conteúdo desta sala.")
     |> redirect(to: ~p"/plans?upgrade=global_catalog")}
  end

  defp content_unavailable(socket) do
    {:ok,
     socket
     |> put_flash(:error, "Este conteúdo não está disponível para a sua conta.")
     |> redirect(to: ~p"/party")}
  end
end
