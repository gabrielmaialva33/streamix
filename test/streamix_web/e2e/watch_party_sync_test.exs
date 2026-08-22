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

  use PhoenixTest.Playwright.Case,
    async: false,
    browser: @playwright_browser,
    browser_pool: false

  use StreamixWeb, :verified_routes

  @moduletag :playwright

  setup {StreamixWeb.PlaywrightSupport, :register_context_cleanup}

  import Phoenix.ConnTest, only: [build_conn: 0, get: 2]
  import Streamix.AccountsFixtures
  import Streamix.IptvFixtures
  import StreamixWeb.ConnCase, only: [log_in_user: 2]

  alias PhoenixTest.Playwright.Case, as: PlaywrightCase
  alias PhoenixTest.Playwright.Config, as: PlaywrightConfig
  alias PlaywrightEx.BrowserContext
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
    guest_session = new_browser_session(context)
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
      |> install_authenticated_cookie(host)
      |> install_media_probe()
      |> visit(~p"/party/#{room.invite_code}/watch")
      |> assert_has("body .phx-connected #video-player-container")

    guest_session =
      guest_session
      |> install_authenticated_cookie(guest)
      |> install_media_probe()
      |> visit(~p"/party/#{room.invite_code}/watch")
      |> assert_has("body .phx-connected #video-player-container")

    wait_for_playback_bridge(host_session)
    wait_for_playback_bridge(guest_session)
    assert_viewer_transport_locked(guest_session)

    host_pause_seek_play(host_session, 33)
    wait_for_playback(guest_session, false, 33)

    host_pause(host_session)
    wait_for_playback(guest_session, true, 33)

    host_play(host_session)
    wait_for_playback(guest_session, false, 33)

    Phoenix.PubSub.subscribe(Streamix.PubSub, Streamix.WatchParty.topic(room.id))
    host_buffering(host_session, true)
    assert_receive {:sync_command, %{host_buffering: true}}, 5_000
    wait_for_playback(guest_session, true, 33)
    wait_for_status(guest_session, "Aguardando o buffer")

    host_buffering(host_session, false)
    wait_for_playback(guest_session, false, 33)

    host_session |> visit(~p"/") |> assert_has("body")
    wait_for_status(guest_session, "Anfitrião desconectado")
    wait_for_playback(guest_session, true, 33)
  end

  defp new_browser_session(context) do
    config =
      context
      |> Map.take(PlaywrightConfig.setup_keys())
      |> PlaywrightConfig.validate!()

    session = PlaywrightCase.new_session(config, context)
    :ok = StreamixWeb.PlaywrightSupport.register_context_cleanup(%{conn: session})
    session
  end

  defp install_authenticated_cookie(session, user) do
    cookie =
      build_conn()
      |> log_in_user(user)
      |> get(~p"/browse/movies")
      |> Map.fetch!(:resp_cookies)
      |> Map.fetch!("_streamix_key")

    PhoenixTest.Playwright.unwrap(session, fn %{context_id: context_id} ->
      {:ok, _} =
        BrowserContext.add_cookies(context_id,
          timeout: 5_000,
          cookies: [
            %{
              "name" => "_streamix_key",
              "value" => cookie.value,
              "url" => StreamixWeb.Endpoint.url(),
              "httpOnly" => true,
              "sameSite" => "Lax"
            }
          ]
        )
    end)
  end

  defp install_media_probe(session) do
    source = """
    (() => {
      window.__streamixLazyHookDiagnostics = true;
      const probe = window.__streamixPartyProbe = {events: []};

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

    PhoenixTest.Playwright.unwrap(session, fn %{context_id: context_id} ->
      {:ok, _} = BrowserContext.add_init_script(context_id, timeout: 5_000, source: source)
    end)
  end

  defp wait_for_playback_bridge(session) do
    PhoenixTest.Playwright.evaluate(
      session,
      """
      () => new Promise((resolve, reject) => {
        const deadline = performance.now() + 8000;
        const check = () => {
          const container = document.getElementById("video-player-container");
          const syncHook = document.getElementById("watch-party-sync")?.__watchPartySyncHook;
          if (container?.streamixPlayback && syncHook?.playback === container.streamixPlayback) {
            return resolve(true);
          }
          if (performance.now() >= deadline) {
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
            const internalHook = mainView?.getHook?.(sync) || null;
            const diagnostics = {
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
              mainViewOwnsElement: mainView?.ownsElement?.(sync) ?? null,
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
            return reject(
              new Error(`watch-party playback bridge unavailable: ${JSON.stringify(diagnostics)}`)
            );
          }
          setTimeout(check, 25);
        };
        check();
      })
      """,
      [is_function: true, timeout: 9_000],
      fn ready -> assert ready end
    )
  end

  defp assert_viewer_transport_locked(session) do
    PhoenixTest.Playwright.evaluate(
      session,
      """
      () => ({
        playDisabled: document.getElementById("play-pause-btn")?.disabled === true,
        speedDisabled: document.getElementById("speed-btn")?.disabled === true,
        progressDisabled:
          document.getElementById("progress-container")?.getAttribute("aria-disabled") === "true",
        role: document.getElementById("video-player-container")?.dataset.partyRole
      })
      """,
      [is_function: true],
      fn state ->
        assert state == %{
                 "playDisabled" => true,
                 "progressDisabled" => true,
                 "role" => "viewer",
                 "speedDisabled" => true
               }
      end
    )
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

    PhoenixTest.Playwright.evaluate(
      session,
      expression,
      [is_function: true, timeout: 5_000],
      fn ready ->
        assert ready
      end
    )
  end

  defp host_pause(session) do
    PhoenixTest.Playwright.evaluate(
      session,
      "async () => { await document.getElementById('video-player-container').streamixPlayback.pause(); return true; }",
      [is_function: true, timeout: 5_000],
      fn ready -> assert ready end
    )
  end

  defp host_play(session) do
    PhoenixTest.Playwright.evaluate(
      session,
      "async () => { await document.getElementById('video-player-container').streamixPlayback.play(); return true; }",
      [is_function: true, timeout: 5_000],
      fn ready -> assert ready end
    )
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

    PhoenixTest.Playwright.evaluate(
      session,
      expression,
      [is_function: true, timeout: 5_000],
      fn dispatched -> assert dispatched end
    )
  end

  defp wait_for_playback(session, paused, position) do
    expression = """
    () => new Promise((resolve, reject) => {
      const deadline = performance.now() + 8000;
      const expectedPaused = #{Jason.encode!(paused)};
      const expectedPosition = #{Jason.encode!(position)};

      const check = () => {
        const playback = document.getElementById("video-player-container")?.streamixPlayback;
        if (playback) {
          const state = {
            paused: playback.isPaused(),
            position: playback.getCurrentTime()
          };
          if (
            state.paused === expectedPaused &&
            Math.abs(state.position - expectedPosition) <= 1.5
          ) return resolve(state);
        }

        if (performance.now() >= deadline) {
          const player = document.getElementById("video-player-container");
          const playback = player?.streamixPlayback;
          const sync = document.getElementById("watch-party-sync");
          const hook = sync?.__watchPartySyncHook;
          const status = document.getElementById("watch-party-sync-status");
          const state = playback
            ? {paused: playback.isPaused(), position: playback.getCurrentTime()}
            : null;
          const hookState = hook
            ? {
                connected: hook.connectedToLiveView,
                destroyed: hook.destroyedHook,
                hasPlayback: Boolean(hook.playback),
                lastSequence: hook.lastServerSequence,
                publishedStatus: hook.lastPublishedStatus,
                syncHold: hook.syncHold
              }
            : null;

          return reject(
            new Error(
              `playback did not synchronize; state=${JSON.stringify(state)}; ` +
                `hook=${JSON.stringify(hookState)}; command=${JSON.stringify(sync?.dataset || {})}; ` +
                `status=${status?.dataset?.syncState || "none"}:${status?.innerText || "none"}`
            )
          );
        }
        setTimeout(check, 25);
      };

      check();
    })
    """

    PhoenixTest.Playwright.evaluate(
      session,
      expression,
      [is_function: true, timeout: 9_000],
      fn state ->
        assert state["paused"] == paused
        assert_in_delta state["position"], position, 1.5
      end
    )
  end

  defp wait_for_status(session, expected_text) do
    expression = """
    () => new Promise((resolve, reject) => {
      const deadline = performance.now() + 8000;
      const expected = #{Jason.encode!(expected_text)};
      const check = () => {
        const text = document.body.innerText || "";
        if (text.includes(expected)) return resolve(text);
        if (performance.now() >= deadline) {
          const status = document.getElementById("watch-party-sync-status");
          const sync = document.getElementById("watch-party-sync");
          const hook = sync?.__watchPartySyncHook;
          const hookState = hook
            ? {
                localBuffering: hook.isBuffering,
                lastSequence: hook.lastServerSequence,
                publishedStatus: hook.lastPublishedStatus,
                syncHold: hook.syncHold,
                syncHoldReason: hook.syncHoldReason
              }
            : null;
          return reject(
            new Error(
              `status not found: ${expected}; state: ${status?.dataset?.syncState || "none"}; ` +
                `rendered: ${status?.innerText || "none"}; hook: ${JSON.stringify(hookState)}; ` +
                `server: ${JSON.stringify(sync?.dataset || {})}; body: ${text}`
            )
          );
        }
        setTimeout(check, 25);
      };
      check();
    })
    """

    PhoenixTest.Playwright.evaluate(
      session,
      expression,
      [is_function: true, timeout: 9_000],
      fn text ->
        assert text =~ expected_text
      end
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
