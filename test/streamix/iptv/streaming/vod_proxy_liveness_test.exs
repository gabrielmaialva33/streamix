defmodule Streamix.Iptv.Streaming.VodProxyLivenessTest do
  use Streamix.DataCase, async: false

  import Plug.Test
  import Streamix.IptvFixtures

  alias Streamix.Iptv.Channels
  alias Streamix.Iptv.LiveChannel
  alias Streamix.Iptv.Movie
  alias Streamix.Iptv.Streaming.{ProviderRuntime, RedirectResolver, VodProxy}
  alias Streamix.Iptv.Streaming.VodProxy.Observability

  setup do
    RedirectResolver.clear_cache()
    ProviderRuntime.reset()

    on_exit(fn ->
      RedirectResolver.clear_cache()
      ProviderRuntime.reset()
    end)
  end

  test "marks a live channel dead on a terminal upstream 404 without poisoning provider health" do
    provider = global_provider_fixture()
    channel = channel_fixture(provider)
    port = start_proxy_server(:terminal)

    VodProxy.pipe(conn(:get, "/proxy"), "http://127.0.0.1:#{port}/stream",
      provider_id: provider.id,
      content_id: channel.id,
      media_type: "channel"
    )

    assert Repo.get!(LiveChannel, channel.id).dead_since
    assert ProviderRuntime.snapshot(provider.id).dimensions.live.status == :unknown
  end

  test "clears a stale dead marker after successful channel playback" do
    provider = global_provider_fixture()
    channel = channel_fixture(provider)
    :ok = Channels.mark_dead(channel.id)
    assert Repo.get!(LiveChannel, channel.id).dead_since

    port = start_proxy_server(:ok)

    VodProxy.pipe(conn(:get, "/proxy"), "http://127.0.0.1:#{port}/stream",
      provider_id: provider.id,
      content_id: channel.id,
      media_type: "channel"
    )

    refute Repo.get!(LiveChannel, channel.id).dead_since
    assert ProviderRuntime.snapshot(provider.id).dimensions.live.status == :healthy
  end

  for status <- [404, 410] do
    test "quarantines VOD on a final upstream #{status} asynchronously" do
      provider = global_provider_fixture()
      movie = movie_fixture(provider)
      port = start_proxy_server(unquote(status))

      VodProxy.pipe(conn(:get, "/proxy"), "http://127.0.0.1:#{port}/stream",
        provider_id: provider.id,
        content_id: movie.id,
        media_type: "movie"
      )

      for pid <- Task.Supervisor.children(Streamix.TaskSupervisor) do
        ref = Process.monitor(pid)
        assert_receive {:DOWN, ^ref, :process, ^pid, _}, 5_000
      end

      assert Repo.get!(Movie, movie.id).dead_since
      assert ProviderRuntime.snapshot(provider.id).dimensions.vod.status == :unknown
    end
  end

  for status <- [403, 503] do
    test "an upstream #{status} does not quarantine a VOD file" do
      provider = global_provider_fixture()
      movie = movie_fixture(provider)
      port = start_proxy_server(unquote(status))

      VodProxy.pipe(conn(:get, "/proxy"), "http://127.0.0.1:#{port}/stream",
        provider_id: provider.id,
        content_id: movie.id,
        media_type: "movie"
      )

      refute Repo.get!(Movie, movie.id).dead_since
    end
  end

  test "a reconnect 404 after media bytes does not quarantine the file" do
    provider = global_provider_fixture()
    movie = movie_fixture(provider)

    state = %{
      provider_id: provider.id,
      content_id: movie.id,
      media_type: "movie",
      dimension: :vod,
      bytes_sent: 1024
    }

    Observability.record_failure(state, {:unexpected_status, 404})
    await_vod_tasks()
    refute Repo.reload!(movie).dead_since
  end

  for method <- [:pipe, :head] do
    test "#{method} mixed failure chain is not definitive file absence" do
      provider = global_provider_fixture()
      movie = movie_fixture(provider)
      first = start_proxy_server({:resolve, 503})
      second = start_proxy_server({:resolve, 404})
      urls = ["http://127.0.0.1:#{first}/stream", "http://127.0.0.1:#{second}/stream"]

      apply(VodProxy, unquote(method), [
        conn(:get, "/proxy"),
        hd(urls),
        [url_chain: urls, provider_id: provider.id, content_id: movie.id, media_type: "movie"]
      ])

      await_vod_tasks()
      refute Repo.reload!(movie).dead_since
    end
  end

  test "a missing source rotates to a live alternate before marking a file dead" do
    provider = global_provider_fixture()
    movie = movie_fixture(provider)
    first = start_proxy_server(:terminal)
    second = start_proxy_server(:ok)
    urls = ["http://127.0.0.1:#{first}/stream", "http://127.0.0.1:#{second}/stream"]

    response =
      VodProxy.pipe(conn(:get, "/proxy"), hd(urls),
        url_chain: urls,
        provider_id: provider.id,
        content_id: movie.id,
        media_type: "movie"
      )

    await_vod_tasks()
    refute Repo.reload!(movie).dead_since
    assert response.resp_body == "stream-bytes"
  end

  for method <- [:pipe, :head] do
    test "#{method} quarantines only when every alternate confirms absence" do
      provider = global_provider_fixture()
      movie = movie_fixture(provider)
      first = start_proxy_server({:resolve, 404})
      second = start_proxy_server({:resolve, 410})
      urls = ["http://127.0.0.1:#{first}/stream", "http://127.0.0.1:#{second}/stream"]

      apply(VodProxy, unquote(method), [
        conn(:get, "/proxy"),
        hd(urls),
        [url_chain: urls, provider_id: provider.id, content_id: movie.id, media_type: "movie"]
      ])

      await_vod_tasks()
      assert Repo.reload!(movie).dead_since
    end
  end

  test "source-proxy resolution does not treat a mixed failure chain as definite absence" do
    provider = global_provider_fixture()
    movie = movie_fixture(provider)
    first = start_proxy_server({:resolve, 404})
    second = start_proxy_server({:resolve, 503})
    urls = ["http://127.0.0.1:#{first}/stream", "http://127.0.0.1:#{second}/stream"]

    assert {:error, _} =
             Streamix.Playback.resolve_stream_url_for_proxy(hd(urls),
               url_chain: urls,
               provider_id: provider.id,
               content_id: movie.id,
               media_type: "movie"
             )

    await_vod_tasks()
    refute Repo.reload!(movie).dead_since
  end

  test "source-proxy resolution records an all-missing chain" do
    provider = global_provider_fixture()
    movie = movie_fixture(provider)
    first = start_proxy_server({:resolve, 404})
    second = start_proxy_server({:resolve, 410})
    urls = ["http://127.0.0.1:#{first}/stream", "http://127.0.0.1:#{second}/stream"]

    assert {:error, _} =
             Streamix.Playback.resolve_stream_url_for_proxy(hd(urls),
               url_chain: urls,
               provider_id: provider.id,
               content_id: movie.id,
               media_type: "movie"
             )

    await_vod_tasks()
    assert Repo.reload!(movie).dead_since
  end

  test "source-proxy resolution tries a live alternate after one missing source" do
    provider = global_provider_fixture()
    movie = movie_fixture(provider)
    first = start_proxy_server({:resolve, 404})
    second = start_proxy_server(:ok)
    urls = ["http://127.0.0.1:#{first}/stream", "http://127.0.0.1:#{second}/stream"]

    assert {:ok, _} =
             Streamix.Playback.resolve_stream_url_for_proxy(hd(urls),
               url_chain: urls,
               provider_id: provider.id,
               content_id: movie.id,
               media_type: "movie"
             )

    await_vod_tasks()
    refute Repo.reload!(movie).dead_since
  end

  defp await_vod_tasks do
    for pid <- Task.Supervisor.children(Streamix.TaskSupervisor) do
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 5_000
    end
  end

  defp start_proxy_server(mode) do
    counter = start_supervised!(Supervisor.child_spec({Agent, fn -> 0 end}, id: make_ref()))

    spec =
      Supervisor.child_spec(
        {Bandit,
         plug: {__MODULE__.StubPlug, mode: mode, counter: counter},
         scheme: :http,
         port: 0,
         ip: :loopback,
         startup_log: false},
        id: make_ref()
      )

    server = start_supervised!(spec)
    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    port
  end

  defmodule StubPlug do
    @moduledoc false

    import Plug.Conn

    def init(opts), do: opts

    def call(conn, opts) do
      mode = Keyword.fetch!(opts, :mode)
      counter = Keyword.fetch!(opts, :counter)
      request_number = Agent.get_and_update(counter, &{&1 + 1, &1 + 1})

      case {mode, request_number} do
        {{:resolve, status}, _} -> send_resp(conn, status, "upstream")
        {status, 1} when is_integer(status) -> send_resp(conn, 200, "resolver")
        {status, _} when is_integer(status) -> send_resp(conn, status, "upstream")
        {:terminal, 1} -> send_resp(conn, 200, "resolver")
        {:terminal, _} -> send_resp(conn, 404, "missing")
        {:ok, 1} -> send_resp(conn, 200, "resolver")
        {:ok, _} -> send_resp(conn, 200, "stream-bytes")
      end
    end
  end
end
