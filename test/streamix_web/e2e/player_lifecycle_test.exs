defmodule StreamixWeb.E2E.PlayerLifecycleTest do
  @moduledoc """
  Browser-level coverage for player lifecycle behavior that is hard to
  validate with static LiveView tests.

  The media element is stubbed in WebKit before app JS runs so the test
  stays deterministic and does not depend on upstream IPTV availability.
  Run with:

      mix test --include playwright test/streamix_web/e2e/player_lifecycle_test.exs
  """

  use PhoenixTest.Playwright.Case, async: false, browser: :webkit
  use StreamixWeb, :verified_routes

  @moduletag :playwright

  import Phoenix.ConnTest, only: [build_conn: 0, get: 2]
  import Streamix.AccountsFixtures
  import Streamix.IptvFixtures
  import StreamixWeb.ConnCase, only: [log_in_user: 2]

  alias PlaywrightEx.BrowserContext

  test "resumes VOD before play and enables native controls on iOS WebKit", %{conn: session} do
    user = user_fixture()
    provider = provider_fixture(user, %{is_active: true, url: StreamixWeb.Endpoint.url()})
    movie = movie_fixture(provider, %{container_extension: "mp4", stream_id: 9_001})

    session
    |> install_authenticated_cookie(user)
    |> install_media_probe(movie.id)
    |> visit(~p"/watch/movie/#{movie.id}")
    |> assert_has("body .phx-connected #video-player-container")
    |> assert_player_resumed_once()
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

  defp install_media_probe(session, content_id) do
    source = """
    (() => {
      const contentId = #{Jason.encode!(to_string(content_id))};
      const positions = {};
      positions[contentId] = {time: 25, duration: 120, timestamp: Date.now()};
      localStorage.setItem("streamix_playback_positions", JSON.stringify(positions));

      Object.defineProperty(navigator, "userAgent", {
        value: "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1",
        configurable: true
      });
      Object.defineProperty(navigator, "platform", {value: "iPhone", configurable: true});
      Object.defineProperty(navigator, "maxTouchPoints", {value: 5, configurable: true});

      window.__streamixPlayerProbe = {events: [], playCalls: 0, loadCalls: 0, currentTime: 0};

      Object.defineProperty(HTMLMediaElement.prototype, "src", {
        configurable: true,
        get() {
          return this.__streamixSrc || "";
        },
        set(value) {
          this.__streamixSrc = value;
        }
      });

      Object.defineProperty(HTMLMediaElement.prototype, "currentTime", {
        configurable: true,
        get() {
          return this.__streamixCurrentTime || 0;
        },
        set(value) {
          const time = Number(value) || 0;
          this.__streamixCurrentTime = time;
          window.__streamixPlayerProbe.currentTime = time;
          window.__streamixPlayerProbe.events.push(`seek:${time}`);
          queueMicrotask(() => {
            this.dispatchEvent(new Event("seeked"));
            this.dispatchEvent(new Event("timeupdate"));
          });
        }
      });

      Object.defineProperty(HTMLMediaElement.prototype, "duration", {
        configurable: true,
        get() {
          return 120;
        }
      });

      Object.defineProperty(HTMLMediaElement.prototype, "readyState", {
        configurable: true,
        get() {
          return 4;
        }
      });

      Object.defineProperty(HTMLMediaElement.prototype, "paused", {
        configurable: true,
        get() {
          return !this.__streamixPlaying;
        }
      });

      HTMLMediaElement.prototype.canPlayType = () => "probably";
      HTMLMediaElement.prototype.load = function () {
        window.__streamixPlayerProbe.loadCalls += 1;
        this.dispatchEvent(new Event("loadedmetadata"));
        this.dispatchEvent(new Event("canplay"));
      };
      HTMLMediaElement.prototype.play = function () {
        this.__streamixPlaying = true;
        window.__streamixPlayerProbe.playCalls += 1;
        window.__streamixPlayerProbe.events.push(`play:${this.currentTime || 0}`);
        this.dispatchEvent(new Event("loadedmetadata"));
        this.dispatchEvent(new Event("canplay"));
        this.dispatchEvent(new Event("playing"));
        this.dispatchEvent(new Event("timeupdate"));
        return Promise.resolve();
      };
      HTMLMediaElement.prototype.pause = function () {
        this.__streamixPlaying = false;
        this.dispatchEvent(new Event("pause"));
      };
    })();
    """

    PhoenixTest.Playwright.unwrap(session, fn %{context_id: context_id} ->
      {:ok, _} = BrowserContext.add_init_script(context_id, timeout: 5_000, source: source)
    end)
  end

  defp assert_player_resumed_once(session) do
    PhoenixTest.Playwright.evaluate(
      session,
      """
      () => new Promise((resolve, reject) => {
        const startedAt = Date.now();

        function snapshot() {
          const video = document.querySelector("#video-element");
          const container = document.querySelector("#video-player-container");
          const bottomControls = document.querySelector("#player-bottom-controls");
          const avMount = document.querySelector("#avplayer-mount");
          const probe = window.__streamixPlayerProbe || {};
          const hook = container && container.__videoPlayerHook;

          return {
            currentTime: video ? video.currentTime : 0,
            nativeControls: video ? video.controls : false,
            bottomControlsHidden: bottomControls ? bottomControls.classList.contains("hidden") : false,
            videoCount: document.querySelectorAll("video").length,
            avChildren: avMount ? avMount.childElementCount : -1,
            nativeTouchControls: hook ? hook.nativeTouchControls : false,
            sessionId: hook ? hook.playbackSessionId : 0,
            events: probe.events || [],
            playCalls: probe.playCalls || 0
          };
        }

        function check() {
          const state = snapshot();
          const seekIndex = state.events.indexOf("seek:25");
          const playIndex = state.events.indexOf("play:25");

          if (
            state.currentTime === 25 &&
            state.playCalls === 1 &&
            seekIndex !== -1 &&
            playIndex !== -1 &&
            seekIndex < playIndex &&
            state.nativeControls &&
            state.nativeTouchControls &&
            state.bottomControlsHidden &&
            state.videoCount === 1 &&
            state.avChildren === 0
          ) {
            resolve(state);
            return;
          }

          if (Date.now() - startedAt > 3000) {
            reject(new Error(`player did not reach expected lifecycle state: ${JSON.stringify(state)}`));
            return;
          }

          setTimeout(check, 50);
        }

        check();
      })
      """,
      [is_function: true, timeout: 4_000],
      fn state ->
        assert state["events"] == ["seek:25", "play:25"]
      end
    )
  end
end
