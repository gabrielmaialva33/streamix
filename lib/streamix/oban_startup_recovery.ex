defmodule Streamix.ObanStartupRecovery do
  @moduledoc """
  Recovers Oban jobs orphaned by a single-node container replacement.

  This child starts after `Streamix.Repo` and before Oban. At that point no
  local queue can be executing work yet, so any row still marked `executing`
  belongs to the previous container. Every orphan becomes `available` and
  gains one attempt, preserving the retry budget consumed when the previous
  container claimed the interrupted execution.

  This must stay disabled in multi-node deployments because another node may
  legitimately own an executing row.
  """

  use GenServer

  import Ecto.Query

  alias Streamix.Repo

  require Logger

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok)
  end

  @impl GenServer
  def init(:ok) do
    case recover() do
      {:ok, %{recovered: 0}} ->
        :ok

      {:ok, %{recovered: recovered}} ->
        Logger.warning("[ObanStartupRecovery] recovered #{recovered} interrupted jobs")

      {:error, reason} ->
        Logger.error("[ObanStartupRecovery] recovery failed: #{inspect(reason)}")
    end

    :ignore
  rescue
    error ->
      Logger.error("[ObanStartupRecovery] recovery crashed: #{Exception.message(error)}")
      :ignore
  end

  @doc """
  Reconciles all currently executing jobs before Oban queues start.
  """
  @spec recover() :: {:ok, %{recovered: non_neg_integer()}} | {:error, term()}
  def recover do
    now = DateTime.utc_now()

    Repo.transaction(fn ->
      {recovered, _} =
        Oban.Job
        |> where([job], job.state == "executing")
        |> Repo.update_all(
          set: [state: "available", scheduled_at: now],
          inc: [max_attempts: 1]
        )

      %{recovered: recovered}
    end)
  end
end
