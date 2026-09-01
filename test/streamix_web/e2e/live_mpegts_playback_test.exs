defmodule StreamixWeb.E2E.LiveMpegtsPlaybackTest do
  @moduledoc """
  Exercises the real browser media pipeline with locally generated MPEG-TS.

  No provider or internet stream participates in these tests. `ffmpeg`
  generates deterministic fixtures and a local Bandit server supplies them to
  the production VideoPlayer hook.
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

  alias PlaywrightEx.BrowserContext
  alias StreamixWeb.PlaywrightMediaFixture

  setup_all do
    directory =
      Path.join(
        System.tmp_dir!(),
        "streamix-playwright-media-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf(directory) end)
    %{media_fixtures: %{h264: PlaywrightMediaFixture.generate!(directory, :h264)}}
  end

  @tag fixture: :h264
  test "plays deterministic H.264/AAC MPEG-TS through the real player", context do
    context.conn
    |> open_live_fixture(context)
    |> assert_mpegts_playing()
  end

  if @playwright_browser == :firefox do
    @tag fixture: :h264, mse_fault: true
    test "bounds incompatible MSE recovery before a stable AVPlayer fallback", context do
      context.conn
      |> open_live_fixture(context)
      |> assert_firefox_avplayer_fallback()
    end
  end

  defp open_live_fixture(
         session,
         %{fixture: fixture, media_fixtures: fixtures} = context
       ) do
    previous_config = Application.get_env(:streamix, :playwright_media_fixture)

    Application.put_env(
      :streamix,
      :playwright_media_fixture,
      PlaywrightMediaFixture.server_config(Map.fetch!(fixtures, fixture), self())
    )

    on_exit(fn ->
      if previous_config do
        Application.put_env(:streamix, :playwright_media_fixture, previous_config)
      else
        Application.delete_env(:streamix, :playwright_media_fixture)
      end
    end)

    media_url = StreamixWeb.Endpoint.url() <> "/__playwright__/media/live.ts"

    user = user_fixture()
    provider = provider_fixture(user, %{is_active: true})
    channel = channel_fixture(provider, %{name: "Deterministic #{fixture} stream"})

    session =
      session
      |> install_authenticated_cookie(user)
      |> install_player_environment()
      |> visit(~p"/watch/live_channel/#{channel.id}")
      |> assert_has("body .phx-connected #video-player-container")
      |> activate_media_url(media_url, Map.get(context, :mse_fault, false))

    assert_receive {:playwright_media_request, "GET", _range}, 5_000
    session
  end

  defp install_authenticated_cookie(session, user) do
    cookie =
      build_conn()
      |> log_in_user(user)
      |> get(~p"/browse")
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

  defp install_player_environment(session) do
    source = """
    (() => {
      window.__streamixLazyHookDiagnostics = true;
      window.__streamixSyntheticMseFaults = 0;
      window.__streamixPlayerConsole = [];

      const formatConsoleValue = (value) => {
        if (value instanceof Error) return `${value.name}: ${value.message}\n${value.stack || ""}`;
        if (typeof value === "string") return value;

        try {
          return JSON.stringify(value);
        } catch (_) {
          return String(value);
        }
      };

      for (const level of ["warn", "error"]) {
        const original = console[level].bind(console);
        console[level] = (...values) => {
          window.__streamixPlayerConsole.push(
            `${level}: ${values.map(formatConsoleValue).join(" ")}`
          );
          original(...values);
        };
      }

      try {
        localStorage.setItem(
          "streamix_player_prefs",
          JSON.stringify({global: {muted: true, volume: 0}})
        );
        localStorage.removeItem("streamix_device_compat");
      } catch (_) {}
    })();
    """

    PhoenixTest.Playwright.unwrap(session, fn %{context_id: context_id} ->
      {:ok, _} = BrowserContext.add_init_script(context_id, timeout: 5_000, source: source)
    end)
  end

  defp activate_media_url(session, media_url, mse_fault?) do
    PhoenixTest.Playwright.evaluate(
      session,
      """
      async ({mediaUrl, mseFault}) => {
        const deadline = performance.now() + 5000;
        let hook = document.getElementById("video-player-container")?.__videoPlayerHook;

        while (!hook && performance.now() < deadline) {
          await new Promise((resolve) => setTimeout(resolve, 25));
          hook = document.getElementById("video-player-container")?.__videoPlayerHook;
        }

        if (!hook) throw new Error("VideoPlayer hook did not mount");

        if (mseFault) {
          // PhoenixTest reserves the context UA for SQL sandbox metadata.
          // Restore browser identity in JavaScript so Firefox policy runs.
          Object.defineProperty(navigator, "userAgent", {
            value: "Mozilla/5.0 (X11; Linux x86_64; rv:144.0) Gecko/20100101 Firefox/144.0",
            configurable: true
          });
        }

        if (mseFault && window.MediaSource?.prototype?.addSourceBuffer) {
          const originalAddSourceBuffer = MediaSource.prototype.addSourceBuffer;

          MediaSource.prototype.addSourceBuffer = function(type) {
            if (String(type).toLowerCase().startsWith("video/mp4")) {
              window.__streamixSyntheticMseFaults += 1;

              if (window.__streamixSyntheticMseFaults >= 2) {
                MediaSource.prototype.addSourceBuffer = originalAddSourceBuffer;
                hook.avPlayerAttempted = false;
              }

              throw new DOMException("Synthetic MPEG-TS MSE incompatibility", "NotSupportedError");
            }

            return originalAddSourceBuffer.call(this, type);
          };
        }

        await hook.playbackEngineTransitionController?.cancel("fixture_override");
        hook.cleanup();
        await (hook._streamLoaderTeardownPromise || Promise.resolve());
        hook.streamUrl = mediaUrl;
        hook.proxyUrl = mediaUrl;
        hook.currentUrl = mediaUrl;
        hook.currentStreamType = "ts";
        hook.useProxy = false;
        hook.retryCount = 0;
        hook.fallbackAttempts = 0;
        hook.avPlayerAttempted = false;
        hook._terminalPlaybackError = false;
        hook.mpegtsRecoveryCoordinator?.reset();
        hook.playerUIController?.showLoading();
        hook.playerUIController?.hideError();
        hook.beginPlaybackSession();
        void hook.playWithMpegts();
        return true;
      }
      """,
      is_function: true,
      arg: %{"mediaUrl" => media_url, "mseFault" => mse_fault?},
      timeout: 6_000
    )
  end

  defp assert_mpegts_playing(session) do
    PhoenixTest.Playwright.evaluate(
      session,
      """
      async () => {
        const deadline = performance.now() + 15000;
        const state = () => {
          const container = document.getElementById("video-player-container");
          const hook = container?.__videoPlayerHook;
          const bridge = container?.streamixPlayback;
          return {
            engine: hook?.getActivePlaybackEngine?.()?.id || null,
            recovery: hook?.mpegtsRecoveryCoordinator?.snapshot?.() || null,
            sessionId: hook?.playbackSessionId || 0,
            terminal: Boolean(hook?._terminalPlaybackError),
            time: Number(bridge?.getCurrentTime?.() || 0)
          };
        };

        let current = state();
        while (
          !(current.engine === "mpegts" && current.time >= 1 && !current.terminal) &&
          performance.now() < deadline
        ) {
          await new Promise((resolve) => setTimeout(resolve, 50));
          current = state();
        }

        if (!(current.engine === "mpegts" && current.time >= 1 && !current.terminal)) {
          throw new Error(`real MPEG-TS playback did not start: ${JSON.stringify(current)}`);
        }

        const before = {time: current.time, sessionId: current.sessionId};
        await new Promise((resolve) => setTimeout(resolve, 1000));
        current = state();

        return {
          before,
          after: {
            engine: current.engine,
            recovery: current.recovery,
            sessionId: current.sessionId,
            terminal: current.terminal,
            time: current.time
          }
        };
      }
      """,
      [is_function: true, timeout: 17_000],
      fn state ->
        assert state["after"]["engine"] == "mpegts"
        assert state["after"]["sessionId"] == state["before"]["sessionId"]
        assert state["after"]["time"] > state["before"]["time"] + 0.5
        assert state["after"]["terminal"] == false
        assert state["after"]["recovery"]["recreateAttempts"] == 0
        assert state["after"]["recovery"]["recoveryActive"] == false
        assert state["after"]["recovery"]["retryScheduled"] == false
      end
    )
  end

  if @playwright_browser == :firefox do
    defp assert_firefox_avplayer_fallback(session) do
      PhoenixTest.Playwright.evaluate(
        session,
        """
        async () => {
          const deadline = performance.now() + 30000;
          const state = () => {
            const container = document.getElementById("video-player-container");
            const hook = container?.__videoPlayerHook;
            return {
              engine: hook?.getActivePlaybackEngine?.()?.id || null,
              avPlayerAttempted: Boolean(hook?.avPlayerAttempted),
              contentType: hook?.contentType || null,
              currentStreamType: hook?.currentStreamType || null,
              hasMpegts: Boolean(hook?.mpegtsPlayer),
              logs: (window.__streamixPlayerConsole || []).slice(-20),
              mseFaults: Number(window.__streamixSyntheticMseFaults || 0),
              recovery: hook?.mpegtsRecoveryCoordinator?.snapshot?.() || null,
              sessionId: hook?.playbackSessionId || 0,
              terminal: Boolean(hook?._terminalPlaybackError),
              usingAVPlayer: Boolean(hook?.usingAVPlayer),
              wantsAVPlayerFallback: Boolean(hook?.shouldPreferAVPlayerForLiveTs?.())
            };
          };

          let current = state();
          while (
            !(
              current.engine === "avplayer" &&
              current.usingAVPlayer &&
              current.mseFaults >= 2 &&
              current.recovery?.recreateAttempts === 1 &&
              !current.recovery?.recoveryActive &&
              !current.recovery?.retryScheduled &&
              !current.terminal
            ) && performance.now() < deadline
          ) {
            await new Promise((resolve) => setTimeout(resolve, 50));
            current = state();
          }

          if (!(current.engine === "avplayer" && current.usingAVPlayer && !current.terminal)) {
            throw new Error(`Firefox fallback did not stabilize: ${JSON.stringify(current)}`);
          }

          const before = current;
          await new Promise((resolve) => setTimeout(resolve, 1500));
          const after = state();
          return {before, after};
        }
        """,
        [is_function: true, timeout: 32_000],
        fn state ->
          assert state["after"]["engine"] == "avplayer"
          assert state["after"]["usingAVPlayer"] == true
          assert state["after"]["hasMpegts"] == false
          assert state["after"]["mseFaults"] >= 2
          assert state["after"]["sessionId"] == state["before"]["sessionId"]
          assert state["after"]["terminal"] == false
          assert state["after"]["recovery"]["recreateAttempts"] == 1
          assert state["after"]["recovery"]["recoveryActive"] == false
          assert state["after"]["recovery"]["retryScheduled"] == false
        end
      )
    end
  end
end
