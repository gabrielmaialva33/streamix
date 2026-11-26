defmodule StreamixWeb.E2E.WatchPartySyncTest do
  @moduledoc """
  Real-browser two-user regression coverage for Watch Party authority, viewer
  controls, buffering, and host disconnect behavior.
  """

  @playwright_browser (case System.get_env("PLAYWRIGHT_BROWSER") do
                         "chromium" -> :chromium
                         "firefox" -> :firefox
                         "webkit" -> :webkit
                         _ -> :webkit
                       end)

  use StreamixWeb.PlaywrightCase, async: false, browser_name: @playwright_browser

  use StreamixWeb, :verified_routes

  @moduletag :playwright

  import Streamix.AccountsFixtures
  import Streamix.IptvFixtures

  alias Fluffy.{Expect, Locator}
  alias Streamix.{Billing, Repo}
  alias Streamix.WatchParty.{Room, RoomServer}

  setup do
    {:ok, server} =
      start_supervised(
        {Bandit,
         plug: __MODULE__.MediaStub, scheme: :http, port: 0, ip: :loopback, startup_log: false}
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    %{media_origin: "http://127.0.0.1:#{port}"}
  end

  test "host commands synchronize a locked viewer and host buffering pauses the room", context do
    host_session = context.conn
    guest_session = start_session(:playwright)
    host = user_fixture()
    guest = user_fixture()
    grant_party_access!([host, guest])

    provider =
      provider_fixture(host, %{
        visibility: "global",
        is_system: true,
        provider_type: "xtream",
        is_active: true,
        url: context.media_origin
      })

    movie =
      movie_fixture(provider, %{
        name: "Two Browser Party Movie",
        container_extension: "mp4",
        duration_secs: 120
      })

    room =
      %Room{}
      |> Room.create_changeset(%{
        host_user_id: host.id,
        catalog_item_id: movie.catalog_item_id,
        source_type: "movie",
        source_id: movie.id
      })
      |> Repo.insert!()

    on_exit(fn -> RoomServer.stop(room.id) end)

    host_session =
      host_session
      |> log_in(host)
      |> install_media_probe()
      |> visit(~p"/party/#{room.invite_code}/watch")
      |> assert_has("#video-player-container")

    guest_session =
      guest_session
      |> log_in(guest)
      |> install_media_probe()
      |> visit(~p"/party/#{room.invite_code}/watch")
      |> assert_has("#video-player-container")

    wait_for_playback_bridge(host_session)
    wait_for_playback_bridge(guest_session)
    assert_viewer_transport_locked(guest_session)

    host_pause_seek_play(host_session, 33)

    try do
      wait_for_playback(guest_session, false, 33)
      host_pause(host_session)
      wait_for_playback(guest_session, true, 33)
    rescue
      error ->
        dump_host_state(host_session)
        reraise error, __STACKTRACE__
    end

    host_play(host_session)
    wait_for_playback(guest_session, false, 33)

    Phoenix.PubSub.subscribe(Streamix.PubSub, Streamix.WatchParty.topic(room.id))

    status =
      "#watch-party-sync-status [data-sync-status-text]"
      |> Locator.by_css()
      |> Locator.filter(visible: true)

    host_buffering(host_session, true)
    assert_receive {:sync_command, %{host_buffering: true}}, 5_000
    wait_for_playback(guest_session, true, 33)

    Expect.expect(guest_session, Expect.to_have_text(status, "Aguardando o buffer"),
      timeout: 8_000
    )

    host_buffering(host_session, false)
    wait_for_playback(guest_session, false, 33)

    visit(host_session, ~p"/")

    Expect.expect(
      guest_session,
      Expect.to_have_text(status, "Anfitrião desconectado — aguardando retorno"),
      timeout: 8_000
    )

    wait_for_playback(guest_session, true, 33)
  end

  defp install_media_probe(session) do
    source = """
    (() => {
      window.__streamixLazyHookDiagnostics = true;
      // This fixture simulates native MP4 playback. Host MediaCapabilities
      // must agree with canPlayType below, or Chromium can select real WASM
      // playback while the test continues controlling the simulated video.
      const decodingInfo = async () => ({
        supported: true,
        smooth: true,
        powerEfficient: true
      });
      if (navigator.mediaCapabilities) {
        Object.defineProperty(navigator.mediaCapabilities, "decodingInfo", {
          value: decodingInfo,
          configurable: true
        });
      } else {
        Object.defineProperty(navigator, "mediaCapabilities", {
          value: {decodingInfo},
          configurable: true
        });
      }

      const probe = window.__streamixPartyProbe = {events: []};
      window.__partyBridgeEvents = [];
      document.addEventListener("streamix:playback", (event) => {
        window.__partyBridgeEvents.push({type: event.detail.type, position: event.detail.position});
      });

      Object.defineProperty(HTMLMediaElement.prototype, "src", {
        configurable: true,
        get() { return this.__partySrc || ""; },
        set(value) { this.__partySrc = value; }
      });

      Object.defineProperty(HTMLMediaElement.prototype, "currentTime", {
        configurable: true,
        get() { return this.__partyCurrentTime || 0; },
        set(value) {
          const time = Number(value) || 0;
          this.__partyCurrentTime = time;
          probe.events.push(`seek:${time}`);
          queueMicrotask(() => {
            this.dispatchEvent(new Event("seeked"));
            this.dispatchEvent(new Event("timeupdate"));
          });
        }
      });

      Object.defineProperty(HTMLMediaElement.prototype, "duration", {
        configurable: true,
        get() { return 120; }
      });

      Object.defineProperty(HTMLMediaElement.prototype, "readyState", {
        configurable: true,
        get() { return 4; }
      });

      Object.defineProperty(HTMLMediaElement.prototype, "paused", {
        configurable: true,
        get() { return !this.__partyPlaying; }
      });

      Object.defineProperty(HTMLMediaElement.prototype, "seekable", {
        configurable: true,
        get() {
          return {
            length: 1,
            start() { return 0; },
            end() { return 120; }
          };
        }
      });

      Object.defineProperty(HTMLMediaElement.prototype, "buffered", {
        configurable: true,
        get() {
          return {
            length: 0,
            start() { return 0; },
            end() { return 0; }
          };
        }
      });

      HTMLMediaElement.prototype.canPlayType = function(type) {
        return /mpegurl/i.test(String(type)) ? "" : "probably";
      };

      HTMLMediaElement.prototype.load = function() {
        this.dispatchEvent(new Event("loadedmetadata"));
        this.dispatchEvent(new Event("canplay"));
      };

      HTMLMediaElement.prototype.play = function() {
        this.__partyPlaying = true;
        probe.events.push(`play:${this.currentTime}`);
        this.dispatchEvent(new Event("play"));
        this.dispatchEvent(new Event("canplay"));
        this.dispatchEvent(new Event("playing"));
        this.dispatchEvent(new Event("timeupdate"));
        return Promise.resolve();
      };

      HTMLMediaElement.prototype.pause = function() {
        this.__partyPlaying = false;
        probe.events.push(`pause:${this.currentTime}`);
        this.dispatchEvent(new Event("pause"));
      };
    })();
    """

    Fluffy.Playwright.add_init_script(session, source)
  end

  defp wait_for_playback_bridge(session) do
    Fluffy.Playwright.wait_for_function(
      session,
      """
      () => {
        const container = document.getElementById("video-player-container");
        const syncHook = document.getElementById("watch-party-sync")?.__watchPartySyncHook;
        return Boolean(
          container?.streamixPlayback && syncHook?.playback === container.streamixPlayback
        );
      }
      """,
      timeout: 8_000,
      polling: 25
    )
  rescue
    error in Fluffy.OperationError ->
      if match?(%Playwright.TimeoutError{}, error.cause), do: dump_bridge_state(session)
      reraise error, __STACKTRACE__
  end

  defp dump_bridge_state(session) do
    state =
      Fluffy.Playwright.evaluate(session, """
      () => {
        const container = document.getElementById("video-player-container");
        const sync = document.getElementById("watch-party-sync");
        const hookElements = Array.from(
          document.querySelectorAll('[phx-hook="WatchPartySync"]')
        ).map((element) => ({
          id: element.id,
          connected: element.isConnected,
          hasHook: Boolean(element.__watchPartySyncHook),
          roomId: element.dataset.roomId || null
        }));
        const mainView = window.liveSocket?.main || null;
        const registeredHook = window.liveSocket?.getHookDefinition?.("WatchPartySync");
        const internalHook = sync && mainView?.getHook?.(sync);
        return {
          lazyError: sync?.dataset?.lazyHookError || null,
          lazyErrorDetail: sync?.dataset?.lazyHookErrorDetail || null,
          globalErrors: window.__streamixLazyHookErrors || null,
          hookRegistered: Boolean(registeredHook),
          registeredMountedType: typeof registeredHook?.mounted,
          registeredMountedSource: String(registeredHook?.mounted || "").slice(0, 180),
          registeredHasBinding: typeof registeredHook?._ensurePlayerBinding === "function",
          appScriptSrc:
            document.querySelector('script[src*="/assets/js/app"]')?.getAttribute("src") || null,
          mainViewExists: Boolean(mainView),
          mainViewOwnsElement: sync ? mainView?.ownsElement?.(sync) ?? null : null,
          internalHookExists: Boolean(internalHook),
          internalMountedType: typeof internalHook?.mounted,
          internalHasBinding: typeof internalHook?._ensurePlayerBinding === "function",
          internalElSame: internalHook?.el === sync,
          internalElConnected: internalHook?.el?.isConnected ?? null,
          internalConnectedState: internalHook?.connectedToLiveView ?? null,
          internalDestroyedState: internalHook?.destroyedHook ?? null,
          internalPlaybackBound: Boolean(internalHook?.playback),
          viewHookCount: mainView?.viewHooks ? Object.keys(mainView.viewHooks).length : null,
          closestViewId: sync?.closest?.("[data-phx-session]")?.id || null,
          phxHookValue: sync?.getAttribute?.("phx-hook") || null,
          syncCount: document.querySelectorAll("#watch-party-sync").length,
          hookElements,
          syncExists: Boolean(sync),
          syncHook: Boolean(sync?.__watchPartySyncHook),
          playerBridge: Boolean(container?.streamixPlayback)
        };
      }
      """)

    IO.puts("Watch Party playback bridge diagnostics: " <> Jason.encode!(state))
  end

  defp assert_viewer_transport_locked(session) do
    state =
      Fluffy.Playwright.evaluate(session, """
      () => ({
        playDisabled: document.getElementById("play-pause-btn")?.disabled === true,
        speedDisabled: document.getElementById("speed-btn")?.disabled === true,
        progressDisabled:
          document.getElementById("progress-container")?.getAttribute("aria-disabled") === "true",
        role: document.getElementById("video-player-container")?.dataset.partyRole
      })
      """)

    assert state == %{
             "playDisabled" => true,
             "progressDisabled" => true,
             "role" => "viewer",
             "speedDisabled" => true
           }
  end

  defp host_pause_seek_play(session, position) do
    expression = """
    async () => {
      const playback = document.getElementById("video-player-container").streamixPlayback;
      if (!playback.isPaused()) await playback.pause();
      await new Promise((resolve) => setTimeout(resolve, 100));
      playback.seekTo(#{Jason.encode!(position)});
      await new Promise((resolve) => setTimeout(resolve, 100));
      await playback.play();
      return true;
    }
    """

    ready = Fluffy.Playwright.evaluate(session, expression)
    assert ready
  end

  defp dump_host_state(session) do
    state =
      Fluffy.Playwright.evaluate(session, """
      () => {
        const player = document.getElementById("video-player-container");
        const hook = player?.__videoPlayerHook;
        const sync = document.getElementById("watch-party-sync");
        return {
          events: window.__streamixPartyProbe?.events,
          paused: player?.streamixPlayback?.isPaused(),
          position: player?.streamixPlayback?.getCurrentTime(),
          engine: player?.streamixPlayback?.engine,
          sourceType: hook?.sourceType,
          selectedEngine: hook?._selectedEngine,
          mediaCapability: hook?.mediaCapabilityProfile,
          session: hook?.playbackSessionId,
          suppressed: hook?._suppressNativePlaybackEvents,
          switching: hook?._switchingToAVPlayer,
          server: sync?.dataset,
          bridgeEvents: window.__partyBridgeEvents
        };
      }
      """)

    IO.puts("Watch Party host failure diagnostics: " <> Jason.encode!(state))
  end

  defp host_pause(session) do
    ready =
      Fluffy.Playwright.evaluate(
        session,
        "async () => { await document.getElementById('video-player-container').streamixPlayback.pause(); return true; }"
      )

    assert ready
  end

  defp host_play(session) do
    ready =
      Fluffy.Playwright.evaluate(
        session,
        "async () => { await document.getElementById('video-player-container').streamixPlayback.play(); return true; }"
      )

    assert ready
  end

  defp host_buffering(session, buffering) do
    expression = """
    async () => {
      await new Promise((resolve) => setTimeout(resolve, 350));
      const player = document.getElementById("video-player-container");
      const hook = player?.__videoPlayerHook;
      if (!hook?.pushEventSafe) return false;

      hook.pushEventSafe("buffering", {buffering: #{Jason.encode!(buffering)}});
      return true;
    }
    """

    dispatched = Fluffy.Playwright.evaluate(session, expression)
    assert dispatched
  end

  defp wait_for_playback(session, paused, position) do
    Fluffy.Playwright.wait_for_function(
      session,
      """
      ({paused, position}) => {
        const playback = document.getElementById("video-player-container")?.streamixPlayback;
        return playback?.isPaused() === paused &&
          Math.abs(playback.getCurrentTime() - position) <= 1.5;
      }
      """,
      %{paused: paused, position: position},
      timeout: 8_000,
      polling: 25
    )
  rescue
    error in Fluffy.OperationError ->
      if match?(%Playwright.TimeoutError{}, error.cause),
        do: dump_playback_state(session, paused, position)

      reraise error, __STACKTRACE__
  end

  defp dump_playback_state(session, paused, position) do
    state =
      Fluffy.Playwright.evaluate(session, """
      () => {
        const playback = document.getElementById("video-player-container")?.streamixPlayback;
        const sync = document.getElementById("watch-party-sync");
        const hook = sync?.__watchPartySyncHook;
        const status = document.querySelector("#watch-party-sync-status [data-sync-status-text]");
        return {
          playback: playback
            ? {paused: playback.isPaused(), position: playback.getCurrentTime()}
            : null,
          hook: hook
            ? {
                connected: hook.connectedToLiveView,
                destroyed: hook.destroyedHook,
                hasPlayback: Boolean(hook.playback),
                lastSequence: hook.lastServerSequence,
                publishedStatus: hook.lastPublishedStatus,
                syncHold: hook.syncHold,
                syncHoldReason: hook.syncHoldReason
              }
            : null,
          command: sync?.dataset || {},
          status: status?.innerText || null
        };
      }
      """)

    IO.puts(
      "Watch Party guest playback diagnostics (expected paused=#{paused}, position=#{position}): " <>
        Jason.encode!(state)
    )
  end

  defp grant_party_access!(users) do
    unique = System.unique_integer([:positive])

    plan =
      Billing.ensure_plan!(%{
        name: "E2E Party #{unique}",
        slug: "e2e-party-#{unique}",
        description: "Two browser Watch Party test",
        price_cents: 0,
        currency: "USD",
        billing_interval: "month",
        active: true,
        grants_global_access: true,
        features: %{global_catalog: true, watch_party: true}
      })

    Enum.each(users, fn user ->
      Billing.ensure_manual_subscription!(user, plan, %{
        status: "active",
        starts_at: DateTime.utc_now(:second),
        external_reference: "e2e-party:#{unique}:#{user.id}"
      })
    end)
  end

  defmodule MediaStub do
    @moduledoc false
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, _opts) do
      conn
      |> put_resp_content_type("video/mp4")
      |> send_resp(200, "")
    end
  end
end
