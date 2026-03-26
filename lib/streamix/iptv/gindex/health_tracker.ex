defmodule Streamix.Iptv.Gindex.HealthTracker do
  @moduledoc """
  Redis-backed health tracking for GIndex endpoints.

  Tracks health per endpoint AND per operation type, allowing:
  - Primary endpoint for listing (works)
  - Fallback endpoint for streaming (when primary has JS errors)

  Uses Redis for:
  - Real-time health state (shared across processes)
  - Error counting with TTL (auto-recovery)
  - Operation-specific circuit breakers
  """

  require Logger

  @redis_prefix "gindex:health:"
  # 5 minutes
  @error_ttl 300
  @error_threshold 3

  @operations [:list, :stream, :file_info]

  @doc """
  Records a successful operation for an endpoint.
  Clears error count for that operation.
  """
  def record_success(endpoint_url, operation) when operation in @operations do
    key = build_key(endpoint_url, operation)
    Redix.command(:streamix_redis, ["DEL", key])
    :ok
  rescue
    _ -> :ok
  end

  @doc """
  Records a failed operation for an endpoint.
  Returns {:ok, :healthy} or {:ok, :unhealthy} based on error count.
  """
  def record_error(endpoint_url, operation, error_type \\ :unknown)
      when operation in @operations do
    key = build_key(endpoint_url, operation)

    case Redix.pipeline(:streamix_redis, [
           ["INCR", key],
           ["EXPIRE", key, @error_ttl]
         ]) do
      {:ok, [count, _]} when is_integer(count) ->
        if count >= @error_threshold do
          Logger.warning(
            "[GIndex HealthTracker] Endpoint #{endpoint_url} unhealthy for #{operation} (#{count} errors, type: #{error_type})"
          )

          {:ok, :unhealthy}
        else
          {:ok, :healthy}
        end

      _ ->
        {:ok, :healthy}
    end
  rescue
    _ -> {:ok, :healthy}
  end

  @doc """
  Checks if an endpoint is healthy for a specific operation.
  """
  def healthy?(endpoint_url, operation) when operation in @operations do
    key = build_key(endpoint_url, operation)

    case Redix.command(:streamix_redis, ["GET", key]) do
      {:ok, nil} -> true
      {:ok, count_str} -> String.to_integer(count_str) < @error_threshold
      _ -> true
    end
  rescue
    _ -> true
  end

  @doc """
  Gets the best endpoint for a specific operation.
  Returns endpoints ordered by health, with healthy ones first.
  """
  def get_best_endpoint_for(endpoints, operation) when operation in @operations do
    endpoints
    |> Enum.sort_by(fn {_name, url, priority} ->
      error_count = get_error_count(url, operation)
      {error_count >= @error_threshold, priority, error_count}
    end)
    |> List.first()
  end

  @doc """
  Gets current health status for all endpoints and operations.
  """
  def get_status(endpoints) do
    Enum.map(endpoints, fn {name, url, priority} ->
      ops_status =
        Enum.map(@operations, fn op ->
          {op,
           %{
             healthy: healthy?(url, op),
             errors: get_error_count(url, op)
           }}
        end)
        |> Map.new()

      %{
        name: name,
        url: url,
        priority: priority,
        operations: ops_status
      }
    end)
  end

  @doc """
  Resets health for all endpoints.
  """
  def reset_all(endpoints) do
    for {_name, url, _priority} <- endpoints,
        operation <- @operations do
      key = build_key(url, operation)
      Redix.command(:streamix_redis, ["DEL", key])
    end

    :ok
  rescue
    _ -> :ok
  end

  # Private

  defp build_key(url, operation) do
    # Hash URL for shorter key
    url_hash = :crypto.hash(:md5, url) |> Base.encode16(case: :lower) |> binary_part(0, 8)
    "#{@redis_prefix}#{url_hash}:#{operation}"
  end

  defp get_error_count(url, operation) do
    key = build_key(url, operation)

    case Redix.command(:streamix_redis, ["GET", key]) do
      {:ok, nil} -> 0
      {:ok, count_str} -> String.to_integer(count_str)
      _ -> 0
    end
  rescue
    _ -> 0
  end
end
