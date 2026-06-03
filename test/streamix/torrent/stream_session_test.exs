defmodule Streamix.Torrent.StreamSessionTest do
  use ExUnit.Case, async: false

  alias Streamix.Torrent.StreamSession

  @info_hash String.duplicate("a", 40)
  @magnet "magnet:?xt=urn:btih:#{String.duplicate("a", 40)}"

  setup do
    # Spin up a fake rqbit so the live Client.add/list/stats path works
    # end-to-end against an in-process Bandit listener.
    {:ok, server, port} = start_rqbit_stub()
    prior = Application.get_env(:streamix, :torrent_provider)

    Application.put_env(:streamix, :torrent_provider,
      enabled: true,
      rqbit_url: "http://127.0.0.1:#{port}"
    )

    # Local registry + supervisor so we don't depend on the application
    # tree (which only starts torrent infra when enabled at boot).
    start_supervised!({Registry, keys: :unique, name: Streamix.Torrent.StreamRegistry})

    start_supervised!(
      {DynamicSupervisor, name: Streamix.Torrent.StreamSessionSupervisor, strategy: :one_for_one}
    )

    on_exit(fn ->
      if prior, do: Application.put_env(:streamix, :torrent_provider, prior)
    end)

    %{stub: server, port: port}
  end

  test "start_or_join boots a session and resolves once rqbit reports live" do
    viewer = self()

    assert {:ok, %{info_hash: hash, file_idx: 0}} =
             StreamSession.start_or_join(@info_hash, @magnet, viewer)

    assert hash == @info_hash
    assert is_pid(StreamSession.whereis(@info_hash))
  end

  test "second join piggy-backs on the same process" do
    viewer = self()
    {:ok, _} = StreamSession.start_or_join(@info_hash, @magnet, viewer)
    pid_first = StreamSession.whereis(@info_hash)

    spawn_link(fn ->
      {:ok, _} = StreamSession.start_or_join(@info_hash, @magnet, self())
      send(viewer, :joined)
    end)

    assert_receive :joined, 5_000
    assert pid_first == StreamSession.whereis(@info_hash)
  end

  test "leave with no remaining viewers schedules idle teardown" do
    viewer = self()
    {:ok, _} = StreamSession.start_or_join(@info_hash, @magnet, viewer)
    pid = StreamSession.whereis(@info_hash)
    ref = Process.monitor(pid)

    StreamSession.leave(@info_hash, viewer)

    # Idle grace is 60s in production; the test only verifies that the
    # process is still alive immediately after the last viewer leaves
    # (idle timer scheduled, not fired).
    refute_receive {:DOWN, ^ref, :process, ^pid, _}, 200
    assert Process.alive?(pid)
  end

  test "viewer crash is auto-cleaned via DOWN monitor" do
    pid_after_join_ref = make_ref()
    parent = self()

    viewer =
      spawn(fn ->
        {:ok, _} = StreamSession.start_or_join(@info_hash, @magnet, self())
        send(parent, {pid_after_join_ref, :joined})

        receive do
          :stop -> :ok
        end
      end)

    assert_receive {^pid_after_join_ref, :joined}, 5_000
    pid = StreamSession.whereis(@info_hash)
    assert is_pid(pid)

    viewer_ref = Process.monitor(viewer)
    Process.exit(viewer, :kill)

    # Wait for the OS to actually tear the viewer down, then a sync probe
    # on the session forces its mailbox to drain — by the time
    # :sys.get_state returns, the session has processed the DOWN message
    # and any subsequent state transitions.
    assert_receive {:DOWN, ^viewer_ref, :process, ^viewer, _}, 1_000
    :sys.get_state(pid)
    assert Process.alive?(pid)
  end

  # ---- rqbit stub ----

  defp start_rqbit_stub do
    {:ok, agent} = Agent.start_link(fn -> %{} end)

    {:ok, server} =
      start_supervised(
        {Bandit,
         plug: {__MODULE__.StubPlug, agent: agent},
         scheme: :http,
         port: 0,
         ip: :loopback,
         startup_log: false}
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    {:ok, server, port}
  end

  defmodule StubPlug do
    @moduledoc false
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, opts) do
      agent = Keyword.fetch!(opts, :agent)
      do_call(conn, agent)
    end

    defp do_call(%{method: "POST", path_info: ["torrents"]} = conn, agent) do
      hash = String.duplicate("a", 40)
      Agent.update(agent, &Map.put(&1, hash, true))

      body = %{
        "id" => 1,
        "info_hash" => hash,
        "name" => "ubuntu",
        "files" => [
          %{"name" => "ubuntu.iso", "length" => 100_000_000, "included" => true}
        ]
      }

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(body))
    end

    defp do_call(%{method: "GET", path_info: ["torrents", _id, "stats", "v1"]} = conn, _agent) do
      body = %{
        "state" => "live",
        "progress_bytes" => 50_000_000,
        "total_bytes" => 100_000_000,
        "finished" => false,
        "live" => %{
          "snapshot" => %{
            "peer_stats" => %{"live" => 5},
            "download_speed" => %{"mbps" => 1_500_000}
          }
        }
      }

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(body))
    end

    defp do_call(%{method: "GET", path_info: ["torrents", _id]} = conn, _agent) do
      body = %{
        "id" => 1,
        "info_hash" => String.duplicate("a", 40),
        "name" => "ubuntu",
        "files" => [
          %{"name" => "ubuntu.iso", "length" => 100_000_000, "included" => true}
        ]
      }

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(body))
    end

    defp do_call(%{method: "GET", path_info: ["torrents"]} = conn, _agent) do
      body = %{
        "torrents" => [
          %{
            "id" => 1,
            "info_hash" => String.duplicate("a", 40),
            "name" => "ubuntu",
            "files" => []
          }
        ]
      }

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(body))
    end

    defp do_call(%{method: "DELETE", path_info: ["torrents", _id]} = conn, _agent) do
      send_resp(conn, 200, "")
    end

    defp do_call(conn, _agent) do
      send_resp(conn, 404, "not found")
    end
  end
end
