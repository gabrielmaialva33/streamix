defmodule Streamix.AI.SearchHealth do
  @moduledoc """
  Bounded, cached semantic-search readiness, shared by health and the API.

  One probe per node every 45 seconds at most unless configuration changes;
  concurrent readers share it.
  Both successful and failed observations are cached as values, independently
  of Cache.fetch's intentional refusal to memoize errors (F10). Fixed monotonic
  expiry avoids extending a hot entry forever and does not depend on Redis.

  The probe exercises the selected provider without fallback and checks the
  actual vector length against every collection's unnamed vector configuration.
  Existing collections do not record embedding provider/model identity: a model
  change with the same dimensions cannot be detected here and still requires
  an operator-managed reindex. Dimension compatibility alone is not provenance.
  """

  use GenServer

  alias Streamix.AI.{Embeddings, Gemini, Nvidia, Qdrant}

  @ttl_ms 45_000
  @probe_timeout_ms 2_000
  @collections ~w(movies series animes user_profiles)a

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Returns a credential-free observation; an unavailable probe fails closed."
  def status do
    if Embeddings.enabled?() and Qdrant.configured?() do
      GenServer.call(__MODULE__, {:status, configuration_key()}, @probe_timeout_ms + 500)
    else
      %{status: :disabled}
    end
  rescue
    _ -> degraded(:probe_failed)
  catch
    :exit, _ -> degraded(:probe_unavailable)
  end

  @impl true
  def init(_opts), do: {:ok, nil}

  @impl true
  def handle_call({:status, key}, _from, cached) do
    now = System.monotonic_time(:millisecond)

    case cached do
      {^key, expires_at, result} when expires_at > now ->
        {:reply, result, cached}

      _ ->
        result = bounded_probe()
        expires_at = System.monotonic_time(:millisecond) + @ttl_ms
        {:reply, result, {key, expires_at, result}}
    end
  end

  defp bounded_probe do
    task = Task.Supervisor.async_nolink(Streamix.TaskSupervisor, &probe/0)

    case Task.yield(task, @probe_timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      {:exit, _} -> degraded(:probe_failed)
      nil -> degraded(:probe_timeout)
    end
  end

  defp probe do
    result =
      case Embeddings.provider() do
        :nvidia -> Nvidia.embed("health", input_type: "query")
        :gemini -> Gemini.embed("health", task_type: "RETRIEVAL_QUERY")
      end

    result
    |> embedding_status()
    |> Map.put(:provider, Embeddings.provider())
  rescue
    _ -> degraded(:probe_failed)
  catch
    _, _ -> degraded(:probe_failed)
  end

  defp embedding_status({:ok, vector}) when is_list(vector) and vector != [] do
    if Enum.all?(vector, &is_number/1) do
      collection_status(length(vector))
    else
      degraded(:invalid_embedding)
    end
  end

  defp embedding_status({:error, {:api_error, status, _body}}),
    do: Map.put(degraded(:embedding_http_error), :http_status, status)

  defp embedding_status({:error, {:quota_exceeded, _body}}),
    do: Map.put(degraded(:embedding_http_error), :http_status, 429)

  defp embedding_status({:error, :not_configured}), do: degraded(:provider_not_configured)
  defp embedding_status({:error, {:request_failed, _}}), do: degraded(:embedding_request_failed)
  defp embedding_status(_), do: degraded(:invalid_embedding)

  defp collection_status(dimensions) do
    collections = Map.new(@collections, &read_collection/1)

    reason =
      cond do
        Enum.any?(collections, fn {_, info} -> info.status == "unavailable" end) ->
          :collections_unavailable

        Enum.any?(collections, fn {_, info} -> not is_integer(info.vector_dimensions) end) ->
          :collection_dimensions_unknown

        dimensions != Embeddings.embedding_dimensions() or
            Enum.any?(collections, fn {_, info} -> info.vector_dimensions != dimensions end) ->
          :reindex_required

        Enum.any?(collections, fn {_, info} -> info.status not in ["green", "yellow"] end) ->
          :collections_unhealthy

        true ->
          nil
      end

    status = if reason, do: degraded(reason), else: %{status: :ok}
    Map.merge(status, %{collections: collections, vector_dimensions: dimensions})
  end

  defp read_collection(name) do
    case Qdrant.collection_info(to_string(name)) do
      {:ok, info} -> {name, info}
      {:error, _} -> {name, %{status: "unavailable"}}
    end
  end

  defp degraded(reason), do: %{status: :degraded, reason: reason}

  defp configuration_key do
    # Hash credential changes too, so a repaired key is probed immediately.
    # Neither credentials nor provider response bodies enter the cached value.
    config =
      Enum.map([:embeddings, :nvidia, :gemini, :qdrant], &Application.get_env(:streamix, &1))

    env =
      Enum.map(
        ~w(EMBEDDING_PROVIDER NVIDIA_API_KEY NVIDIA_EMBEDDING_MODEL GEMINI_API_KEY QDRANT_URL QDRANT_API_KEY),
        &System.get_env/1
      )

    :crypto.hash(:sha256, :erlang.term_to_binary({config, env}))
  end
end
