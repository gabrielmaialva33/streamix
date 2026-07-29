defmodule StreamixWeb.WatchPartyLive.Show do
  @moduledoc """
  Main Watch Party viewing page with synchronized playback and chat.
  """
  use StreamixWeb, :live_view

  import StreamixWeb.PlayerComponents
  import StreamixWeb.PlayerHelpers
  import StreamixWeb.WatchPartyComponents

  alias Streamix.Iptv.CatalogItem
  alias Streamix.Iptv.ContentRef
  alias Streamix.WatchParty
  alias StreamixWeb.Presence

  @presence_topic_prefix "watch_party:presence:"

  @impl true
  def mount(%{"invite_code" => invite_code}, _session, socket) do
    user_id = socket.assigns.current_scope.user.id

    case WatchParty.get_room_by_invite_with_content(invite_code) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, "Watch Party nao encontrada")
         |> redirect(to: ~p"/")}

      room ->
        mount_room(socket, room, user_id)
    end
  end

  defp mount_room(socket, room, user_id) do
    is_host = room.host_user_id == user_id

    catalog_item = room.catalog_item

    content_type = catalog_item.content_type
    content_entity = CatalogItem.content(catalog_item)
    content_id = if content_entity, do: content_entity.id, else: nil

    if is_nil(content_id) do
      {:ok,
       socket
       |> put_flash(:error, "Conteudo nao encontrado")
       |> redirect(to: ~p"/")}
    else
      do_mount_room(socket, room, user_id, is_host, content_type, content_id, ContentRef)
    end
  end

  defp do_mount_room(socket, room, user_id, is_host, content_type, content_id, _content_ref) do
    case load_content(content_type, to_string(content_id), user_id) do
      {:ok, content, provider, stream_url} ->
        WatchParty.ensure_room_server(room)

        role = if is_host, do: "host", else: "viewer"

        case WatchParty.join_room(room.id, user_id, role) do
          {:ok, _participant} ->
            finish_mount_room(
              socket,
              room,
              user_id,
              is_host,
              content_type,
              content,
              provider,
              stream_url
            )

          {:error, :room_full} ->
            {:ok,
             socket
             |> put_flash(:error, "Watch Party cheia")
             |> redirect(to: ~p"/party")}

          {:error, _reason} ->
            {:ok,
             socket
             |> put_flash(:error, "Não foi possível entrar na Watch Party")
             |> redirect(to: ~p"/party")}
        end

      {:error, :not_found} ->
        {:ok,
         socket
         |> put_flash(:error, "Conteudo nao encontrado")
         |> redirect(to: ~p"/")}
    end
  end

  defp finish_mount_room(
         socket,
         room,
         user_id,
         is_host,
         content_type,
         content,
         provider,
         stream_url
       ) do
    if connected?(socket) do
      # Subscribe to room events
      Phoenix.PubSub.subscribe(Streamix.PubSub, WatchParty.topic(room.id))

      # Track presence
      presence_topic = @presence_topic_prefix <> to_string(room.id)
      Phoenix.PubSub.subscribe(Streamix.PubSub, presence_topic)

      Presence.track(self(), presence_topic, to_string(user_id), %{
        user_id: user_id,
        email: socket.assigns.current_scope.user.email,
        is_host: is_host,
        joined_at: System.system_time(:second)
      })
    end

    # Get initial playback state
    playback_state =
      case WatchParty.get_playback_state(room.id) do
        {:ok, playback, _host_id} -> playback
        _ -> %{state: :paused, position: 0.0}
      end

    # Load messages
    messages = WatchParty.list_messages(room.id)

    presence_topic = @presence_topic_prefix <> to_string(room.id)
    presences = Presence.list(presence_topic)

    next_episode = load_next_episode(content_type, content, provider, user_id)

    socket =
      socket
      |> assign(
        page_title:
          "Watch Party — #{Map.get(content, :title) || Map.get(content, :name) || "Conteúdo"}"
      )
      |> assign(room: room)
      |> assign(content: content)
      |> assign(content_type: safe_content_type(content_type))
      |> assign(provider: provider)
      |> assign(stream_url: stream_url)
      |> assign(streaming_mode: default_streaming_mode(content_type))
      |> assign(is_host: is_host)
      |> assign(user_id: user_id)
      |> assign(playback_state: playback_state)
      |> assign(presences: presences)
      |> assign(chat_open: false)
      |> assign(message_input: "")
      |> assign(next_episode: next_episode)
      |> stream(:messages, messages)

    {:ok, socket}
  end

  # --- Event Handlers ---

  @impl true
  def handle_event("wp_play", %{"position" => position}, socket) do
    dispatch_playback(socket, "play", position)
  end

  def handle_event("wp_pause", %{"position" => position}, socket) do
    dispatch_playback(socket, "pause", position)
  end

  def handle_event("wp_seek", %{"position" => position}, socket) do
    dispatch_playback(socket, "seek", position)
  end

  def handle_event("wp_sync_beacon", params, socket) do
    WatchParty.send_sync_beacon(
      socket.assigns.room.id,
      socket.assigns.user_id,
      params["position"] || 0.0,
      params["state"] || "paused",
      params["buffering"] || false,
      params["client_time"] || 0
    )

    {:noreply, socket}
  end

  def handle_event("wp_clock_ping", %{"id" => id}, socket) do
    {:noreply,
     push_event(socket, "wp_clock_pong", %{id: id, server_time: System.system_time(:millisecond)})}
  end

  def handle_event("wp_request_sync", _params, socket) do
    # Immediate sync for newly joined followers
    case WatchParty.get_playback_state(socket.assigns.room.id) do
      {:ok, playback, _host_id} ->
        {:noreply,
         push_event(socket, "wp_sync_command", %{
           type: "sync",
           state: Atom.to_string(playback.state),
           position: playback.position,
           server_time: System.system_time(:millisecond)
         })}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("toggle_chat", _, socket) do
    {:noreply, assign(socket, chat_open: !socket.assigns.chat_open)}
  end

  def handle_event("send_message", %{"message" => content}, socket) when content != "" do
    WatchParty.send_message(socket.assigns.room.id, socket.assigns.user_id, content)
    {:noreply, assign(socket, message_input: "")}
  end

  def handle_event("send_message", _, socket), do: {:noreply, socket}

  def handle_event("send_reaction", %{"emoji" => emoji}, socket) do
    WatchParty.send_message(socket.assigns.room.id, socket.assigns.user_id, emoji, "reaction")
    {:noreply, socket}
  end

  def handle_event("wp_leave", _, socket) do
    WatchParty.leave_room(socket.assigns.room.id, socket.assigns.user_id)
    {:noreply, redirect(socket, to: ~p"/")}
  end

  def handle_event("wp_end_party", _, socket) do
    if socket.assigns.is_host do
      WatchParty.end_room(socket.assigns.room.id, socket.assigns.user_id)
    end

    {:noreply, redirect(socket, to: ~p"/")}
  end

  # Acknowledge player events we don't handle in party mode
  def handle_event("progress_update", _params, socket), do: {:noreply, socket}
  def handle_event("streaming_mode_changed", _params, socket), do: {:noreply, socket}
  def handle_event("qualities_available", _params, socket), do: {:noreply, socket}
  def handle_event("quality_changed", _params, socket), do: {:noreply, socket}
  def handle_event("audio_tracks_available", _params, socket), do: {:noreply, socket}
  def handle_event("subtitle_tracks_available", _params, socket), do: {:noreply, socket}
  def handle_event("buffering", _params, socket), do: {:noreply, socket}
  def handle_event("pip_toggled", _params, socket), do: {:noreply, socket}
  def handle_event("player_initializing", _params, socket), do: {:noreply, socket}
  def handle_event("device_diagnostics", _params, socket), do: {:noreply, socket}
  def handle_event("player_error", _params, socket), do: {:noreply, socket}
  def handle_event("player_debug", _params, socket), do: {:noreply, socket}
  def handle_event("codec_abr_suggestion", _params, socket), do: {:noreply, socket}
  def handle_event("diagnostic_suggestion", _params, socket), do: {:noreply, socket}
  def handle_event("update_watch_time", _params, socket), do: {:noreply, socket}
  def handle_event("close_player", _, socket), do: {:noreply, redirect(socket, to: ~p"/")}
  def handle_event("quality_switched", _params, socket), do: {:noreply, socket}
  def handle_event("playback_rate_changed", _params, socket), do: {:noreply, socket}
  def handle_event("duration_available", _params, socket), do: {:noreply, socket}
  def handle_event("mute_toggled", _params, socket), do: {:noreply, socket}
  def handle_event("volume_changed", _params, socket), do: {:noreply, socket}
  def handle_event("audio_track_changed", _params, socket), do: {:noreply, socket}
  def handle_event("subtitle_track_changed", _params, socket), do: {:noreply, socket}
  def handle_event("pip_error", _params, socket), do: {:noreply, socket}
  def handle_event("request_token_refresh", _params, socket), do: {:noreply, socket}
  def handle_event("avplayer_preference_changed", _params, socket), do: {:noreply, socket}
  def handle_event("set_quality", _params, socket), do: {:noreply, socket}
  def handle_event("set_audio_track", _params, socket), do: {:noreply, socket}
  def handle_event("set_subtitle_track", _params, socket), do: {:noreply, socket}
  def handle_event("toggle_pip", _params, socket), do: {:noreply, socket}

  # --- PubSub Handlers ---

  @impl true
  def handle_info({:sync_command, command}, socket) do
    {:noreply, push_event(socket, "wp_sync_command", command)}
  end

  def handle_info({:new_message, message}, socket) do
    socket =
      socket
      |> stream_insert(:messages, message)
      |> maybe_push_reaction(message)

    {:noreply, socket}
  end

  def handle_info({:participant_joined, _user_id}, socket) do
    {:noreply, update_presences(socket)}
  end

  def handle_info({:participant_left, _user_id}, socket) do
    {:noreply, update_presences(socket)}
  end

  def handle_info(:room_ended, socket) do
    {:noreply,
     socket
     |> put_flash(:info, "O host encerrou a Watch Party")
     |> redirect(to: ~p"/")}
  end

  def handle_info(%Phoenix.Socket.Broadcast{event: "presence_diff"}, socket) do
    {:noreply, update_presences(socket)}
  end

  @impl true
  def terminate(_reason, socket) do
    with %{room: room, user_id: user_id} <- socket.assigns do
      WatchParty.leave_room(room.id, user_id)
    end

    :ok
  rescue
    _ -> :ok
  end

  # --- Private ---

  # Host-only gate moved here from the GenServer so non-host viewers get
  # feedback (flash) instead of a silent noop. The RoomServer also still
  # checks — defence in depth — but the LiveView is where we have UI to
  # tell the user what happened.
  defp dispatch_playback(socket, action, position) do
    if socket.assigns.is_host do
      WatchParty.playback_action(socket.assigns.room.id, socket.assigns.user_id, %{
        "action" => action,
        "position" => position
      })

      {:noreply, socket}
    else
      {:noreply, put_flash(socket, :error, "Apenas o anfitrião pode controlar o player.")}
    end
  end

  defp update_presences(socket) do
    presence_topic = @presence_topic_prefix <> to_string(socket.assigns.room.id)
    assign(socket, presences: Presence.list(presence_topic))
  end

  defp maybe_push_reaction(socket, %{type: "reaction"} = message) do
    push_event(socket, "wp_floating_reaction", %{
      emoji: message.content,
      user_id: message.user_id
    })
  end

  defp maybe_push_reaction(socket, _), do: socket

  defp safe_content_type("live_channel"), do: :live_channel
  defp safe_content_type("movie"), do: :movie
  defp safe_content_type("episode"), do: :episode
  defp safe_content_type("gindex"), do: :gindex
  defp safe_content_type("gindex_episode"), do: :gindex_episode
  defp safe_content_type(_), do: :live_channel
end
