defmodule Streamix.AI.QdrantTest do
  use ExUnit.Case, async: false

  alias Streamix.AI.Qdrant

  test "disabled client fails fast without requiring a Qdrant service" do
    assert Qdrant.enabled?() == false
    assert Qdrant.health_check() == {:error, :disabled}
    assert Qdrant.get_point("movies", 123) == {:error, :disabled}
  end

  test "setup_collections stops on the first collection check failure" do
    {:ok, port, requests} = start_qdrant_stub(500)
    prior = Application.get_env(:streamix, :qdrant)

    Application.put_env(:streamix, :qdrant,
      enabled: true,
      url: "http://127.0.0.1:#{port}"
    )

    on_exit(fn ->
      Application.put_env(:streamix, :qdrant, prior)
    end)

    assert Qdrant.setup_collections() ==
             {:error, {:collection_setup_failed, "movies", {:check_failed, 500}}}

    assert Agent.get(requests, &Enum.reverse/1) == [{"GET", "/collections/movies"}]
  end

  test "setup_collections creates every collection used by semantic search and profiles" do
    {:ok, port, requests} = start_qdrant_stub(:create_missing)
    prior = Application.get_env(:streamix, :qdrant)

    Application.put_env(:streamix, :qdrant,
      enabled: true,
      url: "http://127.0.0.1:#{port}"
    )

    on_exit(fn ->
      Application.put_env(:streamix, :qdrant, prior)
    end)

    assert Qdrant.setup_collections() == :ok

    assert Agent.get(requests, &Enum.reverse/1) == [
             {"GET", "/collections/movies"},
             {"PUT", "/collections/movies"},
             {"GET", "/collections/series"},
             {"PUT", "/collections/series"},
             {"GET", "/collections/animes"},
             {"PUT", "/collections/animes"},
             {"GET", "/collections/user_profiles"},
             {"PUT", "/collections/user_profiles"}
           ]
  end

  defp start_qdrant_stub(mode) do
    {:ok, requests} = Agent.start_link(fn -> [] end)

    {:ok, server} =
      start_supervised(
        {Bandit,
         plug: {__MODULE__.StubPlug, requests: requests, mode: mode},
         scheme: :http,
         port: 0,
         ip: :loopback,
         startup_log: false}
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    {:ok, port, requests}
  end

  defmodule StubPlug do
    @moduledoc false
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, opts) do
      requests = Keyword.fetch!(opts, :requests)
      mode = Keyword.fetch!(opts, :mode)

      Agent.update(requests, &[{conn.method, conn.request_path} | &1])
      send_resp(conn, response_status(mode, conn.method), Jason.encode!(%{"status" => "ok"}))
    end

    defp response_status(:create_missing, "GET"), do: 404
    defp response_status(:create_missing, "PUT"), do: 200
    defp response_status(status, _method) when is_integer(status), do: status
  end
end
