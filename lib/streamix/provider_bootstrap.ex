defmodule Streamix.ProviderBootstrap do
  @moduledoc false

  alias Streamix.Iptv.{GIndexProvider, GlobalProvider, TorrentProvider}
  alias Streamix.Repo

  require Logger

  @max_repo_attempts 10

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary,
      type: :worker
    }
  end

  def start_link(_opts) do
    Task.start_link(&run/0)
  end

  defp run do
    case wait_for_repo() do
      :ok -> init_system_providers()
      :error -> :ok
    end
  rescue
    error ->
      Logger.error(
        "[Application] System provider bootstrap crashed: " <>
          Exception.format(:error, error, __STACKTRACE__)
      )
  end

  defp wait_for_repo(attempt \\ 0) do
    case Repo.query("SELECT 1") do
      {:ok, _result} ->
        :ok

      {:error, _reason} when attempt < @max_repo_attempts ->
        Process.sleep(retry_delay(attempt))
        wait_for_repo(attempt + 1)

      {:error, reason} ->
        Logger.warning(
          "[Application] Repo not ready after #{@max_repo_attempts} attempts: #{inspect(reason)}"
        )

        :error
    end
  end

  defp retry_delay(attempt) do
    min(:timer.seconds(5), trunc(100 * :math.pow(2, attempt)))
  end

  defp init_system_providers do
    ensure_provider("GIndex", &GIndexProvider.ensure_exists!/0)
    ensure_provider("Global", &GlobalProvider.ensure_exists!/0)
    ensure_provider("Torrent", &TorrentProvider.ensure_exists!/0)
  end

  defp ensure_provider(name, ensure_exists) do
    case ensure_exists.() do
      {:ok, _provider} ->
        :ok

      {:error, reason} ->
        Logger.warning("[Application] #{name} provider init failed: #{inspect(reason)}")
    end
  end
end
