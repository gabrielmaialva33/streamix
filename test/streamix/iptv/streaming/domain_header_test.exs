defmodule Streamix.Iptv.Streaming.DomainHeaderTest do
  use Streamix.DataCase, async: false

  import Streamix.IptvFixtures
  alias Streamix.Iptv.Streaming.{DeliveryProbe, XtreamHls}
  alias Streamix.Iptv.XtreamClient

  @panel "93.184.216.34"
  @cdn "104.16.1.1"

  setup do
    for key <- [:iptv_x_domain, :xtream_delivery, :xtream_hls] do
      original = Application.get_env(:streamix, key)

      on_exit(fn ->
        if original == nil,
          do: Application.delete_env(:streamix, key),
          else: Application.put_env(:streamix, key, original)
      end)
    end

    Application.put_env(:streamix, :iptv_x_domain, "public.example")
    Application.put_env(:streamix, :xtream_delivery, http_options: [plug: {Req.Test, __MODULE__}])

    Application.put_env(:streamix, :xtream_hls,
      http_options: [plug: {Req.Test, __MODULE__}],
      prefetch_segments: 0
    )

    Req.Test.set_req_test_to_shared()
    :ok
  end

  for enabled <- [true, false] do
    @enabled enabled
    test "API and XMLTV requests scope domain identity, enabled=#{enabled}" do
      {:ok, server} =
        start_supervised(
          {Bandit,
           plug: {__MODULE__.Panel, parent: self()},
           scheme: :http,
           port: 0,
           ip: :loopback,
           startup_log: false}
        )

      {:ok, {_, port}} = ThousandIsland.listener_info(server)
      url = "http://127.0.0.1:#{port}"
      provider = global_provider_fixture(%{url: url, send_x_domain: @enabled})

      opts = [
        provider: provider,
        provider_id: provider.id,
        allow_private_network: true,
        max_retries: 0
      ]

      assert {:ok, %{}} = XtreamClient.get_account_info(url, "u", "p", opts)
      assert {:ok, "{}"} = XtreamClient.get_xmltv(url, "u", "p", opts)

      for _ <- 1..2 do
        assert_receive {:request, "127.0.0.1", headers}
        assert headers == if(@enabled, do: ["public.example"], else: [])
        assert_receive {:request, "localhost", []}
      end
    end

    for delivery <- [:pipe_stream, :pipe_live_stream, :head_stream] do
      @delivery delivery
      test "#{delivery} scopes actual media requests, enabled=#{enabled}" do
        {:ok, server} =
          start_supervised(
            {Bandit,
             plug: {__MODULE__.Panel, parent: self()},
             scheme: :http,
             port: 0,
             ip: :loopback,
             startup_log: false}
          )

        {:ok, {_, port}} = ThousandIsland.listener_info(server)
        url = "http://127.0.0.1:#{port}"
        provider = global_provider_fixture(%{url: url, send_x_domain: @enabled})
        method = if @delivery == :head_stream, do: :head, else: :get

        response =
          apply(Streamix.Playback, @delivery, [
            Plug.Test.conn(method, "/"),
            url <> "/movie/u/p/1.ts",
            [
              provider_id: provider.id,
              content_id: provider.id,
              media_type: "movie",
              url_validator: fn _ -> :ok end
            ]
          ])

        assert response.status == 200
        assert_receive {:request, "127.0.0.1", headers}
        assert headers == if(@enabled, do: ["public.example"], else: [])
        assert_receive {:request, "localhost", []}
        refute_receive {:request, "localhost", [_ | _]}
      end
    end

    test "movie, episode and live probes strip domain identity after redirect, enabled=#{enabled}" do
      provider = global_provider_fixture(%{url: "https://#{@panel}", send_x_domain: @enabled})
      stub_chain()

      for type <- [:movie, :episode, :channel] do
        content = %{
          id: System.unique_integer([:positive]),
          stream_id: 11,
          episode_id: 12,
          source_ids: [1],
          container_extension: "mp4"
        }

        assert {:ok, {:hls, _}} = DeliveryProbe.decide(provider, type, content)
        assert_hops(@enabled)
      end
    end

    test "HLS gateway scopes root and redirected fetch, enabled=#{enabled}" do
      provider = global_provider_fixture(%{url: "https://#{@panel}", send_x_domain: @enabled})
      content = {:movie, System.unique_integer([:positive])}
      stub_chain()

      assert {:ok, session} =
               XtreamHls.open(content, provider.id, "https://#{@panel}/movie/u/p/1.m3u8")

      assert {:ok, _} =
               XtreamHls.fetch_master(session.session_id, session.resource_id, content,
                 resource_url: fn s, r -> "/#{s}/#{r}" end
               )

      assert_hops(@enabled)
    end

    test "proxy resolver scopes every hop, enabled=#{enabled}" do
      provider = global_provider_fixture(%{url: "https://#{@panel}", send_x_domain: @enabled})
      stub_chain()

      assert {:ok, _} =
               Streamix.Playback.resolve_stream_url("https://#{@panel}/movie/u/p/1.mp4",
                 provider_id: provider.id,
                 stop_fn: fn _ -> false end,
                 req_options: [plug: {Req.Test, __MODULE__}]
               )

      assert_hops(@enabled)
    end
  end

  test "credential exchange cache is reused under the same domain policy" do
    provider = global_provider_fixture(%{url: "https://#{@panel}", send_x_domain: true})
    stub_chain()
    url = "https://#{@panel}/movie/u/p/#{provider.id}.mp4"
    opts = [provider_id: provider.id, req_options: [plug: {Req.Test, __MODULE__}]]
    assert {:ok, _} = Streamix.Playback.resolve_stream_url_for_proxy(url, opts)
    assert_receive {:request, @panel, ["public.example"]}
    refute_receive {:request, @cdn, _}
    assert {:ok, _} = Streamix.Playback.resolve_stream_url(url, opts)
    assert_receive {:request, @cdn, []}
    refute_receive {:request, @panel, _}
  end

  test "invalid override cannot become an injected header" do
    provider = global_provider_fixture(%{url: "https://#{@panel}", send_x_domain: true})
    Application.put_env(:streamix, :iptv_x_domain, "example.com\r\nx-injected: yes")
    stub_chain()

    assert {:ok, _} =
             Streamix.Playback.resolve_stream_url("https://#{@panel}/movie/u/p/1.mp4",
               provider: provider,
               stop_fn: fn _ -> false end,
               req_options: [plug: {Req.Test, __MODULE__}]
             )

    assert_hops(false)
  end

  defp stub_chain do
    owner = self()

    Req.Test.stub(__MODULE__, fn conn ->
      send(owner, {:request, conn.host, Plug.Conn.get_req_header(conn, "x-domain")})

      if conn.host == @panel do
        conn
        |> Plug.Conn.put_resp_header("location", "https://#{@cdn}/master.m3u8")
        |> Plug.Conn.send_resp(302, "")
      else
        conn
        |> Plug.Conn.put_resp_content_type("application/vnd.apple.mpegurl")
        |> Plug.Conn.send_resp(200, "#EXTM3U\n#EXT-X-ENDLIST\n")
      end
    end)
  end

  defp assert_hops(enabled) do
    assert_receive {:request, @panel, headers}
    assert headers == if(enabled, do: ["public.example"], else: [])
    assert_receive {:request, @cdn, []}
  end

  defmodule Panel do
    import Plug.Conn
    def init(opts), do: opts

    def call(conn, opts) do
      send(opts[:parent], {:request, conn.host, get_req_header(conn, "x-domain")})

      if conn.host == "127.0.0.1" do
        conn
        |> put_resp_header("location", "http://localhost:#{conn.port}/final#{conn.request_path}")
        |> send_resp(302, "")
      else
        if String.contains?(conn.request_path, ".ts") do
          conn
          |> put_resp_content_type("video/mp2t")
          |> send_resp(200, :binary.copy(<<0x47>>, 188))
        else
          conn |> put_resp_content_type("application/json") |> send_resp(200, "{}")
        end
      end
    end
  end
end
