defmodule Streamix.AI.QdrantTest do
  use ExUnit.Case, async: false

  alias Streamix.AI.Qdrant
  alias Streamix.AI.ScoreThresholds

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

  # The default floors are calibrated per embedding model; a hard-coded 0.7
  # here once silently emptied every "similar titles" answer.
  test "searches default to the calibrated floor, and an explicit floor wins" do
    {:ok, port, requests} = start_qdrant_stub(:search)
    prior = Application.get_env(:streamix, :qdrant)
    Application.put_env(:streamix, :qdrant, enabled: true, url: "http://127.0.0.1:#{port}")
    on_exit(fn -> Application.put_env(:streamix, :qdrant, prior) end)

    assert {:ok, []} = Qdrant.find_similar("movies", 123)
    assert {:ok, []} = Qdrant.find_similar("movies", 123, score_threshold: 0.9)
    assert {:ok, []} = Qdrant.search("movies", [0.1, 0.2])

    thresholds =
      requests
      |> Agent.get(&Enum.reverse/1)
      |> Enum.flat_map(fn
        {"POST", "/collections/movies/points/search", body} -> [body["score_threshold"]]
        _request -> []
      end)

    assert thresholds == [ScoreThresholds.similar(), 0.9, ScoreThresholds.similar()]
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

      record(conn, requests, mode)
    end

    defp record(conn, requests, :search) do
      {:ok, raw, conn} = read_body(conn)

      entry =
        if conn.method == "POST",
          do: {conn.method, conn.request_path, Jason.decode!(raw)},
          else: {conn.method, conn.request_path}

      Agent.update(requests, &[entry | &1])

      result =
        if conn.method == "GET",
          do: %{"id" => 123, "vector" => [0.1, 0.2], "payload" => %{}},
          else: []

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(%{"result" => result}))
    end

    defp record(conn, requests, mode) do
      Agent.update(requests, &[{conn.method, conn.request_path} | &1])
      send_resp(conn, response_status(mode, conn.method), Jason.encode!(%{"status" => "ok"}))
    end

    defp response_status(:create_missing, "GET"), do: 404
    defp response_status(:create_missing, "PUT"), do: 200
    defp response_status(status, _method) when is_integer(status), do: status
  end
end
