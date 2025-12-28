defmodule Streamix.Iptv.ErrorHandler do
  @moduledoc """
  Standardized error handling and logging for IPTV operations.

  Provides consistent error logging with context, preventing silent failures
  and making debugging easier.
  """

  require Logger

  @doc """
  Logs an API error with context and returns the error.
  """
  def log_api_error(operation, context, reason) do
    Logger.warning("[IPTV] #{operation} failed",
      context: context,
      reason: inspect(reason)
    )

    {:error, {operation, reason}}
  end

  @doc """
  Logs a warning for partial/fallback data.
  """
  def log_fallback(operation, context, message) do
    Logger.info("[IPTV] #{operation} using fallback: #{message}",
      context: context
    )
  end

  @doc """
  Wraps an operation with error logging.
  Returns {:ok, result} or {:error, reason} with logging.
  """
  def with_logging(operation, context, fun) do
    case fun.() do
      {:ok, result} ->
        {:ok, result}

      {:error, reason} ->
        log_api_error(operation, context, reason)

      nil ->
        log_api_error(operation, context, :not_found)

      result ->
        {:ok, result}
    end
  rescue
    e ->
      Logger.error("[IPTV] #{operation} raised exception",
        context: context,
        exception: Exception.format(:error, e, __STACKTRACE__)
      )

      {:error, {operation, :exception}}
  end

  @doc """
  Safely executes a function, returning default on error.
  Logs any errors that occur.
  """
  def safe_call(operation, context, default, fun) do
    case with_logging(operation, context, fun) do
      {:ok, result} -> result
      {:error, _} -> default
    end
  end
end
