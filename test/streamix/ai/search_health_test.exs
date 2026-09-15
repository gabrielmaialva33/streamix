defmodule Streamix.AI.SearchHealthTest do
  use StreamixWeb.ConnCase, async: false

  alias Streamix.AI
  alias Streamix.OperationalHealth
  alias StreamixWeb.Api.V1.SearchController

  setup do
    original =
      Map.new([:embeddings, :nvidia, :gemini, :qdrant], &{&1, Application.get_env(:streamix, &1)})

    req_options = Req.default_options()
    owner = self()

    upstream =
      start_supervised!(
        {Agent, fn -> %{response: 410, dimensions: 1024, calls: 0, owner: owner} end}
      )

    Application.put_env(:streamix, :embeddings, provider: "nvidia")
    Application.put_env(:streamix, :nvidia, api_key: "test-#{System.unique_integer([:positive])}")
    Application.put_env(:streamix, :gemini, api_key: "")
    Application.put_env(:streamix, :qdrant, enabled: true, url: "http://qdrant.test")
    Req.default_options(plug: fn conn -> respond(conn, upstream) end)

    on_exit(fn ->
      Req.default_options(req_options)

      Enum.each(original, fn
        {key, nil} -> Application.delete_env(:streamix, key)
        {key, value} -> Application.put_env(:streamix, key, value)
      end)
    end)

    %{upstream: upstream}
  end

  test "readiness and search status report a dead provider despite green collections", %{
    conn: conn,
    upstream: upstream
  } do
    assert %{status: :degraded, reason: :embedding_http_error, http_status: 410} =
             OperationalHealth.snapshot().checks.semantic_search

    body = conn |> SearchController.status(%{}) |> json_response(200)
    assert body["available"] == false
    assert body["status"] == "degraded"
    assert body["reason"] == "embedding_http_error"
    assert body["http_status"] == 410
    refute inspect(body) =~ "private upstream detail"
    assert Agent.get(upstream, & &1.calls) == 1
  end

  test "a live provider with incompatible collection dimensions requires reindexing", %{
    conn: conn,
    upstream: upstream
  } do
    Agent.update(upstream, &%{&1 | response: 200, dimensions: 3072})
    body = conn |> SearchController.status(%{}) |> json_response(200)
    assert body["available"] == false
    assert body["status"] == "degraded"
    assert body["reason"] == "reindex_required"
  end

  test "successful probes are cached and concurrent callers share a single request", %{
    conn: conn,
    upstream: upstream
  } do
    Agent.update(upstream, &%{&1 | response: 200})

    results =
      1..12 |> Task.async_stream(fn _ -> AI.semantic_search_available?() end) |> Enum.to_list()

    assert Enum.all?(results, &(&1 == {:ok, true}))
    body = conn |> SearchController.status(%{}) |> json_response(200)
    assert body["available"] == true
    assert body["status"] == "ok"
    assert body["stats"]["movies"]["points_count"] == 10
    assert Agent.get(upstream, & &1.calls) == 1
  end

  test "missing configuration is disabled without an embedding call", %{
    conn: conn,
    upstream: upstream
  } do
    Application.put_env(:streamix, :nvidia, api_key: "")
    body = conn |> SearchController.status(%{}) |> json_response(200)
    assert body["status"] == "disabled"
    assert body["available"] == false
    assert Agent.get(upstream, & &1.calls) == 0
  end

  test "timeouts are bounded, terminate the probe, and are cached", %{upstream: upstream} do
    Agent.update(upstream, &%{&1 | response: :blocked})
    started = System.monotonic_time(:millisecond)
    task = Task.async(fn -> AI.semantic_search_status() end)
    assert_receive {:probe_started, pid}, 1_000
    monitor = Process.monitor(pid)
    assert %{status: :degraded, reason: :probe_timeout} = Task.await(task)
    assert System.monotonic_time(:millisecond) - started < 2_800
    assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}
    assert %{reason: :probe_timeout} = AI.semantic_search_status()
    assert Agent.get(upstream, & &1.calls) == 1
  end

  test "401 is cached as a degraded observation", %{upstream: upstream} do
    Agent.update(upstream, &%{&1 | response: 401})
    assert %{status: :degraded, http_status: 401} = AI.semantic_search_status()
    assert %{status: :degraded, http_status: 401} = AI.semantic_search_status()
    assert Agent.get(upstream, & &1.calls) == 1
  end

  test "probe exceptions cannot crash the health and are cached", %{upstream: upstream} do
    Agent.update(upstream, &%{&1 | response: :raise})
    assert %{status: :degraded, reason: :probe_failed} = AI.semantic_search_status()
    assert %{status: :degraded, reason: :probe_failed} = AI.semantic_search_status()
    assert Agent.get(upstream, & &1.calls) == 1
  end

  test "reads do not extend expiry and the provider is probed again after expiry", %{
    upstream: upstream
  } do
    assert %{status: :degraded} = AI.semantic_search_status()
    {_, expires_at, _} = :sys.get_state(Streamix.AI.SearchHealth)
    Agent.update(upstream, &%{&1 | response: 200})
    assert %{status: :degraded} = AI.semantic_search_status()
    assert {_, ^expires_at, _} = :sys.get_state(Streamix.AI.SearchHealth)

    :sys.replace_state(Streamix.AI.SearchHealth, fn {key, _, result} ->
      {key, System.monotonic_time(:millisecond) - 1, result}
    end)

    assert %{status: :ok} = AI.semantic_search_status()
    assert Agent.get(upstream, & &1.calls) == 2
  end

  test "switching to live Gemini cannot make the old NVIDIA index ready", %{upstream: upstream} do
    Application.put_env(:streamix, :embeddings, provider: "gemini")
    Application.put_env(:streamix, :gemini, api_key: "test-gemini")

    assert %{status: :degraded, reason: :reindex_required, vector_dimensions: 3072} =
             AI.semantic_search_status()

    assert Agent.get(upstream, & &1.calls) == 0
  end

  test "unknown collection dimensions are not reported as compatible", %{upstream: upstream} do
    Agent.update(upstream, &%{&1 | response: 200, dimensions: nil})

    assert %{status: :degraded, reason: :collection_dimensions_unknown} =
             AI.semantic_search_status()
  end

  defp respond(%{request_path: "/v1/embeddings"} = conn, upstream) do
    response = Agent.get_and_update(upstream, &{&1.response, %{&1 | calls: &1.calls + 1}})

    case response do
      :blocked ->
        send(Agent.get(upstream, & &1.owner), {:probe_started, self()})

        receive do
          :release -> :ok
        end

      :raise ->
        raise "private upstream detail"

      _ ->
        :ok
    end

    body =
      if response == 200,
        do: %{data: [%{index: 0, embedding: List.duplicate(0.1, 1024)}]},
        else: %{error: "private upstream detail"}

    conn |> put_resp_content_type("application/json") |> send_resp(response, Jason.encode!(body))
  end

  defp respond(%{request_path: "/collections/" <> _} = conn, upstream) do
    size = Agent.get(upstream, & &1.dimensions)

    Req.Test.json(conn, %{
      result: %{
        status: "green",
        points_count: 10,
        vectors_count: 10,
        config: %{params: %{vectors: %{size: size, distance: "Cosine"}}}
      }
    })
  end

  defp respond(
         %{request_path: "/v1beta/models/gemini-embedding-001:embedContent"} = conn,
         _upstream
       ) do
    Req.Test.json(conn, %{embedding: %{values: List.duplicate(0.1, 3072)}})
  end

  defp respond(conn, _upstream), do: Req.Test.json(conn, %{version: "test"})
end
