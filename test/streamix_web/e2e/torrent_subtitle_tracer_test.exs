defmodule StreamixWeb.E2E.TorrentSubtitleTracerTest do
  @moduledoc """
  Thin browser tracer for the highest-risk playback path.

  It owns every dependency: an in-process rqbit stub, a fixed subtitle
  provider and a stubbed media element. No external torrent, provider,
  codec or subtitle API is needed.
  """

  use PhoenixTest.Playwright.Case,
    async: false,
    parameterize: [
      %{browser_pool: false, browser: :chromium},
      %{browser_pool: false, browser: :firefox}
    ]

  use StreamixWeb, :verified_routes

  @moduletag :playwright

  setup {StreamixWeb.PlaywrightSupport, :register_context_cleanup}

  import Phoenix.ConnTest, only: [build_conn: 0, get: 2]
  import Streamix.AccountsFixtures
  import Streamix.IptvFixtures
  import StreamixWeb.ConnCase, only: [log_in_user: 2]

  alias PlaywrightEx.BrowserContext
  alias Streamix.Cache
  alias Streamix.Iptv.TorrentProvider
  alias Streamix.Repo
  alias Streamix.Torrent.TorrentStream

  @info_hash String.duplicate("e", 40)
  @imdb_id "tt0111161"

  defmodule SubtitleStub do
    @behaviour Streamix.Subtitles.Source

    def slug, do: "e2e-tracer"
    def enabled?, do: true

    def fetch(_imdb_id, _lang) do
      {:ok, "1\n00:00:01,000 --> 00:00:02,000\nTracer PT-BR\n"}
    end
  end

  setup do
    {:ok, server, port} = start_rqbit_stub()
    previous_torrent = Application.get_env(:streamix, :torrent_provider)
    previous_subtitles = Application.get_env(:streamix, :subtitle_providers)

    Application.put_env(:streamix, :torrent_provider,
      enabled: true,
      rqbit_url: "http://127.0.0.1:#{port}"
    )

    Application.put_env(:streamix, :subtitle_providers, [SubtitleStub])
    Cache.delete("subtitles:vtt:e2e-tracer:#{@imdb_id}:pt-br")

    start_supervised!({Registry, keys: :unique, name: Streamix.Torrent.StreamRegistry})

    start_supervised!(
      {DynamicSupervisor, name: Streamix.Torrent.StreamSessionSupervisor, strategy: :one_for_one}
    )

    on_exit(fn ->
      restore_env(:torrent_provider, previous_torrent)
      restore_env(:subtitle_providers, previous_subtitles)
      Cache.delete("subtitles:vtt:e2e-tracer:#{@imdb_id}:pt-br")
    end)

    %{rqbit: server}
  end

  test "opens a ready torrent and exposes shifted external subtitles", %{conn: session} do
    user = admin_user_fixture()

    {:ok, user} =
      Streamix.Accounts.update_user_settings(user, %{
        subtitles_enabled: true,
        subtitle_language: "pt-BR",
        subtitle_offset_ms: 500
      })

    {:ok, provider} = TorrentProvider.ensure_exists!()
    movie = movie_fixture(provider, %{name: "Torrent Tracer", imdb_id: @imdb_id})

    stream =
      %TorrentStream{}
      |> TorrentStream.changeset(%{
        info_hash: @info_hash,
        magnet_uri: "magnet:?xt=urn:btih:#{@info_hash}",
        source_slug: "e2e",
        movie_id: movie.id
      })
      |> Repo.insert!()

    session
    |> install_authenticated_cookie(user)
    |> install_media_stub()
    |> visit(~p"/watch/torrent/#{stream.id}?return_to=/torrent")
    |> assert_has("#video-player-container", timeout: 8_000)
    |> assert_tracer_state()
  end

  defp install_authenticated_cookie(session, user) do
    cookie =
      build_conn()
      |> log_in_user(user)
      |> get(~p"/torrent")
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

  defp install_media_stub(session) do
    source = """
    (() => {
      Object.defineProperty(HTMLMediaElement.prototype, "src", {
        configurable: true,
        get() { return this.__streamixSrc || ""; },
        set(value) { this.__streamixSrc = value; }
      });
      Object.defineProperty(HTMLMediaElement.prototype, "readyState", {
        configurable: true,
        get() { return 4; }
      });
      Object.defineProperty(HTMLMediaElement.prototype, "duration", {
        configurable: true,
        get() { return 120; }
      });
      Object.defineProperty(HTMLMediaElement.prototype, "paused", {
        configurable: true,
        get() { return !this.__playing; }
      });
      Object.defineProperty(HTMLMediaElement.prototype, "currentTime", {
        configurable: true,
        get() { return this.__currentTime ?? 1; },
        set(value) { this.__currentTime = Number(value) || 0; }
      });
      Object.defineProperty(HTMLMediaElement.prototype, "webkitAudioDecodedByteCount", {
        configurable: true,
        get() { return 1024; }
      });
      Object.defineProperty(HTMLMediaElement.prototype, "audioTracks", {
        configurable: true,
        get() { return {length: 1}; }
      });
      HTMLMediaElement.prototype.canPlayType = () => "probably";
      HTMLMediaElement.prototype.load = function () {
        queueMicrotask(() => this.dispatchEvent(new Event("loadedmetadata")));
      };
      HTMLMediaElement.prototype.play = function () {
        this.__playing = true;
        queueMicrotask(() => {
          this.dispatchEvent(new Event("loadedmetadata"));
          this.dispatchEvent(new Event("canplay"));
          this.dispatchEvent(new Event("playing"));
        });
        return Promise.resolve();
      };
      HTMLMediaElement.prototype.pause = function () {
        this.__playing = false;
        this.dispatchEvent(new Event("pause"));
      };
    })();
    """

    PhoenixTest.Playwright.unwrap(session, fn %{context_id: context_id} ->
      {:ok, _} = BrowserContext.add_init_script(context_id, timeout: 5_000, source: source)
    end)
  end

  defp assert_tracer_state(session) do
    PhoenixTest.Playwright.evaluate(
      session,
      """
      async () => {
        const deadline = Date.now() + 8_000;
        let container;
        let hook;
        let track;

        while (Date.now() < deadline) {
          container = document.querySelector("#video-player-container");
          hook = container?.__videoPlayerHook;
          track = document.querySelector("#video-element track");

          if (
            hook?.playbackSessionId > 0 &&
            hook?._nativeExternalSubtitleTrack?.isConnected &&
            track?.isConnected
          ) {
            break;
          }

          await new Promise((resolve) => setTimeout(resolve, 100));
        }
        const subtitleResponse = await fetch(
          "/api/subtitles/#{@imdb_id}?lang=pt-BR&offset_ms=500"
        );
        const shifted = await subtitleResponse.text();

        return {
          streamUrl: container?.dataset.streamUrl,
          subtitleLang: container?.dataset.subtitleLang,
          subtitleOffsetMs: container?.dataset.subtitleOffsetMs,
          trackLabel: track?.label,
          trackCount: document.querySelectorAll("#video-element track").length,
          subtitleOptions: document.querySelector("#subtitle-options")?.innerHTML,
          hookState: hook && {
            sourceType: hook.sourceType,
            imdbId: hook.imdbId,
            sessionId: hook.playbackSessionId,
            externalLoadedFor: hook._externalSubtitleLoadedFor,
            sameVideoNode: hook.video === document.querySelector("#video-element"),
            nativeTrackConnected: hook._nativeExternalSubtitleTrack?.isConnected,
            tracks: hook.subtitleTracks
          },
          subtitleStatus: subtitleResponse.status,
          shifted
        };
      }
      """,
      [is_function: true, timeout: 12_000],
      fn state ->
        assert String.starts_with?(state["streamUrl"], "/api/stream/torrent/")
        assert state["subtitleLang"] == "pt-BR"
        assert state["subtitleOffsetMs"] == "500"
        assert state["hookState"]["sameVideoNode"]
        assert state["hookState"]["nativeTrackConnected"]
        assert state["trackLabel"] == "Português (auto)", inspect(state)
        assert state["trackCount"] == 1, inspect(state)
        assert state["subtitleOptions"] =~ "Português (auto)", inspect(state)
        assert state["subtitleStatus"] == 200
        assert state["shifted"] =~ "00:00:01.500 --> 00:00:02.500"
      end
    )
  end

  defp start_rqbit_stub do
    {:ok, server} =
      start_supervised(
        {Bandit,
         plug: __MODULE__.RqbitStub, scheme: :http, port: 0, ip: :loopback, startup_log: false}
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    {:ok, server, port}
  end

  defp restore_env(key, nil), do: Application.delete_env(:streamix, key)
  defp restore_env(key, value), do: Application.put_env(:streamix, key, value)

  defmodule RqbitStub do
    @moduledoc false
    import Plug.Conn

    alias StreamixWeb.E2E.TorrentSubtitleTracerTest, as: TracerTest

    def init(opts), do: opts

    def call(%{method: "POST", path_info: ["torrents"]} = conn, _opts) do
      json(conn, %{
        "id" => 1,
        "info_hash" => TracerTest.info_hash(),
        "name" => "tracer.mp4",
        "files" => [%{"name" => "tracer.mp4", "length" => 20_000_000, "included" => true}]
      })
    end

    def call(%{method: "GET", path_info: ["torrents", _hash, "stats", "v1"]} = conn, _opts) do
      json(conn, %{
        "state" => "live",
        "progress_bytes" => 10_000_000,
        "total_bytes" => 20_000_000,
        "finished" => false,
        "live" => %{
          "snapshot" => %{
            "peer_stats" => %{"live" => 8},
            "download_speed" => %{"mbps" => 2_000_000}
          }
        }
      })
    end

    def call(%{method: "GET", path_info: ["torrents"]} = conn, _opts) do
      json(conn, %{"torrents" => []})
    end

    def call(%{method: "DELETE", path_info: ["torrents", _hash]} = conn, _opts) do
      send_resp(conn, 200, "")
    end

    def call(conn, _opts), do: send_resp(conn, 404, "not found")

    defp json(conn, body) do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(body))
    end
  end

  @doc false
  def info_hash, do: @info_hash
end
