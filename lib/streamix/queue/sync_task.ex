defmodule Streamix.Queue.SyncTask do
  @moduledoc """
  Validates and executes one distributed sync task.

  RabbitMQ payloads are external input, so this module owns their decoding,
  shape validation, provider lookup and retry classification. The Broadway
  pipeline remains a transport adapter and domain work crosses only the public
  IPTV and GIndex facades.
  """

  alias Streamix.Gindex
  alias Streamix.Iptv

  @type task_type :: String.t()
  @type failure_action :: :discard | :retry
  @type execute_option :: {:iptv, module()} | {:gindex, module()}
  @type outcome ::
          {:ok, task_type(), term()}
          | {:error, task_type() | nil, term(), failure_action()}

  @iptv_tasks %{
    "iptv_categories" => {:categories, :categories},
    "iptv_live" => {:live, :live_channels},
    "iptv_movies" => {:movies, :movies},
    "iptv_series" => {:series, :series}
  }

  @gindex_tasks %{
    "gindex_movies" => :movies,
    "gindex_series" => :series,
    "gindex_animes" => :animes
  }

  @supported_types ["gindex_full_sync" | Map.keys(@gindex_tasks) ++ Map.keys(@iptv_tasks)]

  @doc false
  @spec supported_type?(term()) :: boolean()
  def supported_type?(type) when is_atom(type), do: supported_type?(Atom.to_string(type))
  def supported_type?(type) when is_binary(type), do: type in @supported_types
  def supported_type?(_type), do: false

  @doc """
  Decodes and executes a JSON task payload.

  Invalid or permanently unprocessable tasks are marked `:discard`, allowing
  the RabbitMQ adapter to dead-letter them immediately. Runtime failures are
  marked `:retry` and keep the queue's bounded retry policy.

  The dependency options are intentionally explicit so routing and failure
  behavior can be tested without a live provider or RabbitMQ connection.
  """
  @spec execute(term(), [execute_option()]) :: outcome()
  def execute(payload, opts \\ [])

  def execute(payload, opts) when is_binary(payload) and is_list(opts) do
    case Jason.decode(payload) do
      {:ok, task} ->
        execute_task(task, opts)

      {:error, %Jason.DecodeError{position: position}} ->
        {:error, nil, {:invalid_json, %{position: position}}, :discard}
    end
  end

  def execute(_payload, opts) when is_list(opts) do
    {:error, nil, {:invalid_task, :expected_binary}, :discard}
  end

  defp execute_task(%{"type" => type} = task, opts)
       when is_binary(type) and byte_size(type) in 1..100 do
    case run_task(type, task, opts) do
      {:ok, result} -> {:ok, type, result}
      {:error, reason} -> {:error, type, reason, failure_action(reason)}
      _result -> {:error, type, :invalid_handler_result, :retry}
    end
  end

  defp execute_task(%{}, _opts), do: {:error, nil, {:invalid_task, :type}, :discard}

  defp execute_task(_task, _opts),
    do: {:error, nil, {:invalid_task, :expected_object}, :discard}

  defp run_task("gindex_full_sync", task, opts) do
    iptv = Keyword.get(opts, :iptv, Iptv)
    gindex = Keyword.get(opts, :gindex, Gindex)

    with {:ok, provider} <- fetch_provider(task, iptv) do
      gindex.sync_provider(provider)
    end
  end

  defp run_task(type, task, opts) do
    cond do
      Map.has_key?(@gindex_tasks, type) -> run_gindex_path(type, task, opts)
      Map.has_key?(@iptv_tasks, type) -> run_iptv_section(type, task, opts)
      true -> {:error, {:unknown_task_type, type}}
    end
  end

  defp run_gindex_path(type, task, opts) do
    iptv = Keyword.get(opts, :iptv, Iptv)
    gindex = Keyword.get(opts, :gindex, Gindex)
    kind = Map.fetch!(@gindex_tasks, type)

    with {:ok, provider} <- fetch_provider(task, iptv),
         {:ok, path} <- fetch_path(task) do
      gindex.sync_path(provider, path, kind)
    end
  end

  defp run_iptv_section(type, task, opts) do
    iptv = Keyword.get(opts, :iptv, Iptv)
    {section, result_key} = Map.fetch!(@iptv_tasks, type)

    with {:ok, provider} <- fetch_provider(task, iptv),
         {:ok, count} when is_integer(count) and count >= 0 <-
           iptv.sync_provider_section(provider, section) do
      {:ok, %{result_key => count}}
    else
      {:ok, count} -> {:error, {:invalid_sync_count, section, count}}
      {:error, _reason} = error -> error
    end
  end

  defp fetch_provider(task, iptv) do
    with {:ok, provider_id} <- fetch_provider_id(task) do
      case iptv.get_provider(provider_id) do
        %{id: ^provider_id} = provider -> {:ok, provider}
        nil -> {:error, :provider_not_found}
        _result -> {:error, :invalid_provider_result}
      end
    end
  end

  defp fetch_provider_id(%{"provider_id" => provider_id}) do
    case parse_positive_integer(provider_id) do
      {:ok, parsed} -> {:ok, parsed}
      :error -> {:error, {:invalid_task, :provider_id}}
    end
  end

  defp fetch_provider_id(_task), do: {:error, {:invalid_task, :provider_id}}

  defp parse_positive_integer(value) when is_integer(value) and value > 0, do: {:ok, value}

  defp parse_positive_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed > 0 -> {:ok, parsed}
      _other -> :error
    end
  end

  defp parse_positive_integer(_value), do: :error

  defp fetch_path(%{"path" => path}) when is_binary(path) do
    if String.trim(path) == "", do: {:error, {:invalid_task, :path}}, else: {:ok, path}
  end

  defp fetch_path(_task), do: {:error, {:invalid_task, :path}}

  defp failure_action({:invalid_task, _field}), do: :discard
  defp failure_action({:unknown_task_type, _type}), do: :discard
  defp failure_action(:provider_not_found), do: :discard
  defp failure_action(:not_gindex_provider), do: :discard
  defp failure_action(:not_xtream_provider), do: :discard
  defp failure_action(:invalid_sync_path), do: :discard
  defp failure_action({:unsupported_kind, _kind}), do: :discard
  defp failure_action({:unsupported_sync_section, _section}), do: :discard
  defp failure_action(_reason), do: :retry
end
