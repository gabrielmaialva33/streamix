defmodule StreamixWeb.XtreamDirectControllerTest do
  use StreamixWeb.ConnCase, async: false

  import ExUnit.CaptureLog
  import Streamix.AccountsFixtures
  import Streamix.IptvFixtures

  alias Streamix.Iptv.{Episode, Provider, Season}
  alias Streamix.{Providers, Repo}
  alias StreamixWeb.Catalog.StreamUrls
  alias StreamixWeb.Endpoint
  alias StreamixWeb.PlayerHelpers
  alias StreamixWeb.StreamToken

  @user "megauser"
  @pass "s3cr3t-Pa55word"
  @panel "93.184.216.34"
  @redirector "104.16.1.1"
  @cdn "104.16.2.2"
  @final "https://#{@cdn}/movies/7/7.mp4?username=#{@user}&token=tkn-123"

  setup do
    originals =
      for key <- [:xtream_delivery, :xtream_hls, :api_keys],
          do: {key, Application.get_env(:streamix, key)}

    http = [http_options: [plug: {Req.Test, __MODULE__}]]
    Application.put_env(:streamix, :xtream_delivery, http)
    Application.put_env(:streamix, :xtream_hls, http)
    Req.Test.set_req_test_to_shared()

    on_exit(fn ->
      for {key, value} <- originals, do: Application.put_env(:streamix, key, value || [])
    end)

    provider =
      global_provider_fixture(%{
        url: "http://#{@panel}",
        username: @user,
        password: @pass,
        direct_client_playback: true
      })

    movie = movie_fixture(provider, %{container_extension: "mp4", stream_id: 100_664})
    token = StreamToken.sign_movie(movie.id, nil, bypass_subscription: true)

    owner = self()

    Req.Test.stub(__MODULE__, fn conn ->
      send(owner, {:hop, conn.host, conn.request_path, conn.query_string})
      blocked_chain(conn)
    end)

    %{provider: provider, movie: Repo.preload(movie, :provider), token: token}
  end

  test "an authorized request is redirected to the CDN URL resolved server-side", context do
    response = get(build_conn(), direct_path(context.token))

    assert response.status == 302
    assert get_resp_header(response, "location") == [@final]
    assert get_resp_header(response, "cache-control") == ["no-store"]
    assert get_resp_header(response, "referrer-policy") == ["no-referrer"]
    assert get_resp_header(response, "access-control-allow-origin") == ["*"]
    assert response.resp_body == ""
    refute Enum.any?(response.resp_headers, fn {_name, value} -> value =~ @pass end)

    assert_received {:hop, @panel, "/movie/megauser/s3cr3t-Pa55word/100664.mp4", "source=1"}
    assert_received {:hop, @redirector, _path, _query}
    assert_received {:hop, @cdn, _path, _query}

    # Seeks and reconnects reuse the resolution, for HEAD too.
    head_response = head(build_conn(), direct_path(context.token))
    assert head_response.status == 302
    assert get_resp_header(head_response, "location") == [@final]
    refute_received {:hop, _host, _path, _query}
  end

  describe "authorization" do
    test "refused tokens never trigger a probe", context do
      assert get(build_conn(), "/api/stream/vod/direct.mp4").status == 400
      assert get(build_conn(), direct_path("bad")).status == 401

      expired =
        Phoenix.Token.encrypt(
          Endpoint,
          "stream",
          %{type: "movie", id: context.movie.id, user_id: nil, bypass: true},
          signed_at: System.system_time(:second) - 7_300
        )

      assert json_response(get(build_conn(), direct_path(expired)), 401)["error"]["code"] ==
               "token_expired"

      unentitled = StreamToken.sign_movie(context.movie.id, nil)
      response = get(build_conn(), direct_path(unentitled))
      assert json_response(response, 403)["error"]["code"] == "subscription_required"

      stranger = user_fixture()
      private = provider_fixture(user_fixture(), %{url: "http://#{@panel}"})
      private_movie = movie_fixture(private, %{container_extension: "mp4"})
      token = StreamToken.sign_movie(private_movie.id, stranger.id)

      assert json_response(get(build_conn(), direct_path(token)), 403)["error"]["code"] ==
               "token_unauthorized"

      refute_received {:hop, _host, _path, _query}
    end

    test "inactive and degraded providers refuse without a probe", context do
      {:ok, disabled} = Providers.update_provider(context.provider, %{is_active: false})
      response = get(build_conn(), direct_path(context.token))
      assert json_response(response, 503)["error"]["code"] == "provider_disabled"

      disabled
      |> Ecto.Changeset.change(is_active: true, health_status: :degraded)
      |> Repo.update!()

      response = get(build_conn(), direct_path(context.token))
      assert json_response(response, 503)["error"]["code"] == "provider_degraded"
      refute_received {:hop, _host, _path, _query}
    end

    test "an unflagged provider's progressive items are not served here" do
      provider = global_provider_fixture(%{url: "http://#{@panel}"})
      movie = provider |> movie_fixture(%{container_extension: "mp4"}) |> Repo.preload(:provider)
      token = StreamToken.sign_movie(movie.id, nil, bypass_subscription: true)

      response = get(build_conn(), direct_path(token))
      assert json_response(response, 409)["error"]["code"] == "stream_format_mismatch"

      assert StreamUrls.signed_movie_url(movie) =~ "/api/stream/proxy?token="
      assert StreamUrls.browser_movie_url(movie) =~ "/proxy?url="
      refute_received {:hop, _host, _path, _query}
    end

    test "the flag is an operator switch, never accepted from a provider owner" do
      owner = user_fixture()
      provider = provider_fixture(owner, %{url: "http://#{@panel}"})

      changeset = Provider.user_changeset(provider, %{direct_client_playback: true})
      refute Ecto.Changeset.changed?(changeset, :direct_client_playback)
    end
  end

  describe "items the probe sends to the HLS gateway" do
    setup do
      owner = self()

      Req.Test.stub(__MODULE__, fn conn ->
        send(owner, {:hop, conn.host, conn.request_path, conn.query_string})

        case conn.host do
          @panel ->
            conn
            |> put_resp_header("location", "https://#{@redirector}/hls/master.m3u8")
            |> send_resp(302, "")

          _cdn ->
            conn
            |> put_resp_content_type("application/vnd.apple.mpegurl", nil)
            |> send_resp(200, "#EXTM3U\n#EXTINF:6,\nseg.ts\n#EXT-X-ENDLIST\n")
        end
      end)

      :ok
    end

    test "a catalogue mp4 that answers HLS plays through the gateway", context do
      assert StreamUrls.signed_movie_url(context.movie) =~ "/api/stream/hls/master.m3u8?token="

      response = get(build_conn(), "/api/stream/hls/master.m3u8?token=#{encoded(context.token)}")
      assert response.status == 200
      assert response.resp_body =~ ~r{^/api/stream/hls/[^/]+/[^/]+\.ts\?token=}m
      refute response.resp_body =~ @pass

      # The gateway is rooted at the probed source.
      assert_received {:hop, @panel, _path, "source=1"}

      response = get(build_conn(), direct_path(context.token))
      assert json_response(response, 409)["error"]["code"] == "stream_format_mismatch"
    end
  end

  describe "minted URLs" do
    test "progressive items of a flagged provider get the container-suffixed direct route",
         context do
      signed = StreamUrls.signed_movie_url(context.movie)
      assert signed =~ ~r{/api/stream/vod/direct\.mp4\?token=[^&]+$}

      # Never through the stream proxy: its egress is the refused address.
      browser = StreamUrls.browser_movie_url(context.movie)
      assert browser =~ ~r{^https?://[^/]+/api/stream/vod/direct\.mp4\?token=}

      assert {:ok, watch} =
               PlayerHelpers.resolve_stream_url("movie", context.movie, context.provider, nil)

      assert watch =~ "/api/stream/vod/direct.mp4?token="

      proxied = get(build_conn(), "/api/stream/proxy?token=#{encoded(context.token)}")
      assert redirected_to(proxied) == direct_path(context.token)

      Application.put_env(:streamix, :api_keys, ["direct-test-key"])

      api =
        build_conn()
        |> put_req_header("x-api-key", "direct-test-key")
        |> get("/api/v1/catalog/movies/#{context.movie.id}/stream")

      assert json_response(api, 200)["data"]["stream_url"] =~ "/api/stream/vod/direct.mp4?token="
    end

    test "a dead item reports not-found through the proxy redirect", context do
      Req.Test.stub(__MODULE__, &send_resp(&1, 404, "No playable stream found."))

      assert StreamUrls.signed_movie_url(context.movie) =~ "/api/stream/proxy?token="

      response = get(build_conn(), "/api/stream/proxy?token=#{encoded(context.token)}")
      assert json_response(response, 404)["error"]["code"] == "upstream_not_found"
    end

    test "episodes are probed on the series path and minted the same way", context do
      episode = episode_fixture(context.provider)
      token = StreamToken.sign_episode(episode.id, nil, bypass_subscription: true)

      assert StreamUrls.signed_episode_url(Repo.preload(episode, season: [series: :provider])) =~
               "/api/stream/vod/direct.mp4?token="

      assert_received {:hop, @panel, path, "source=1"}
      assert path == "/series/megauser/s3cr3t-Pa55word/#{episode.episode_id}.mp4"

      response = get(build_conn(), direct_path(token))
      assert get_resp_header(response, "location") == [@final]
    end
  end

  test "no log line carries the password, the username or the CDN URL", context do
    log =
      capture_log([level: :debug], fn ->
        assert get(build_conn(), direct_path(context.token)).status == 302

        Req.Test.stub(__MODULE__, &send_resp(&1, 404, "gone"))
        movie = movie_fixture(context.provider, %{container_extension: "mkv"})
        token = StreamToken.sign_movie(movie.id, nil, bypass_subscription: true)

        assert get(build_conn(), "/api/stream/vod/direct.mkv?token=#{encoded(token)}").status ==
                 404
      end)

    for secret <- [@pass, @user, "tkn-123", @cdn] do
      refute log =~ secret
    end
  end

  defp direct_path(token), do: "/api/stream/vod/direct.mp4?token=#{encoded(token)}"
  defp encoded(token), do: URI.encode_www_form(token)

  defp blocked_chain(%{host: @panel} = conn) do
    conn
    |> put_resp_header("location", "https://#{@redirector}/r/abc")
    |> send_resp(302, "")
  end

  defp blocked_chain(%{host: @redirector} = conn) do
    conn
    |> put_resp_header(
      "location",
      "http://#{@cdn}:80/movies/7/7.mp4?username=#{@user}&token=tkn-123"
    )
    |> send_resp(302, "")
  end

  defp blocked_chain(%{host: @cdn} = conn) do
    conn
    |> put_resp_content_type("text/html")
    |> send_resp(403, "<title>Attention Required! | Cloudflare</title>")
  end

  defp episode_fixture(provider) do
    series = series_content_fixture(provider)

    season =
      %Season{}
      |> Season.changeset(%{season_number: 1, name: "T1", series_id: series.id})
      |> Repo.insert!()

    catalog_item = catalog_item_fixture("episode", provider.id)

    %Episode{}
    |> Episode.changeset(%{
      episode_id: System.unique_integer([:positive]),
      episode_num: 1,
      title: "S01E01",
      container_extension: "mp4",
      season_id: season.id
    })
    |> Ecto.Changeset.put_change(:catalog_item_id, catalog_item.id)
    |> Repo.insert!()
  end
end
