defmodule Streamix.Iptv.Torrent.ReaperTest do
  use ExUnit.Case, async: false

  alias Streamix.Iptv.Torrent.Reaper

  setup do
    {:ok, server, port, agent} = start_rqbit_stub()
    prior = Application.get_env(:streamix, :torrent_provider)

    Application.put_env(:streamix, :torrent_provider,
      enabled: true,
      rqbit_url: "http://127.0.0.1:#{port}"
    )

    # Spin up the registry so the Reaper can check it.
    start_supervised!({Registry, keys: :unique, name: Streamix.Iptv.Torrent.StreamRegistry})

    on_exit(fn ->
      if prior, do: Application.put_env(:streamix, :torrent_provider, prior)
    end)

    %{stub: server, port: port, agent: agent}
  end

  test "reaps torrents that have no matching session", %{agent: agent} do
    # Seed the stub with one torrent rqbit knows about but Streamix
    # doesn't (no Registry entry).
    Agent.update(agent, fn state ->
      Map.put(state, :torrents, [
        %{
          "id" => 1,
          "info_hash" => String.duplicate("a", 40),
          "name" => "orphan",
          "files" => []
        }
      ])
    end)

    {:ok, _pid} = start_supervised({Reaper, [interval: :timer.minutes(60)]})
    Reaper.sweep_now()

    # The stub records DELETEs in the agent under :deleted.
    Process.sleep(50)
    deleted = Agent.get(agent, &Map.get(&1, :deleted, []))
    assert String.duplicate("a", 40) in deleted
  end

  test "leaves alone torrents that have a registered session", %{agent: agent} do
    info_hash = String.duplicate("b", 40)

    Agent.update(agent, fn state ->
      Map.put(state, :torrents, [
        %{"id" => 2, "info_hash" => info_hash, "name" => "registered", "files" => []}
      ])
    end)

    # Pretend a StreamSession owns this hash.
    {:ok, _} = Registry.register(Streamix.Iptv.Torrent.StreamRegistry, info_hash, :session)

    {:ok, _pid} = start_supervised({Reaper, [interval: :timer.minutes(60)]})
    Reaper.sweep_now()

    Process.sleep(50)
    deleted = Agent.get(agent, &Map.get(&1, :deleted, []))
    refute info_hash in deleted
  end

  # ---- rqbit stub ----

  defp start_rqbit_stub do
    {:ok, agent} = Agent.start_link(fn -> %{torrents: [], deleted: []} end)

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
    {:ok, server, port, agent}
  end

  defmodule StubPlug do
    @moduledoc false
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, opts) do
      agent = Keyword.fetch!(opts, :agent)
      do_call(conn, agent)
    end

    defp do_call(%{method: "GET", path_info: ["torrents"]} = conn, agent) do
      torrents = Agent.get(agent, &Map.get(&1, :torrents, []))

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(%{"torrents" => torrents}))
    end

    defp do_call(%{method: "DELETE", path_info: ["torrents", id]} = conn, agent) do
      Agent.update(agent, fn state ->
        Map.update(state, :deleted, [id], &[id | &1])
      end)

      send_resp(conn, 200, "")
    end

    defp do_call(conn, _agent), do: send_resp(conn, 404, "")
  end
end
