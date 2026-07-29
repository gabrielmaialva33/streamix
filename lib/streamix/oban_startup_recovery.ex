defmodule Streamix.ObanStartupRecovery do
  @moduledoc """
  Recovers Oban jobs orphaned by a single-node container replacement.

  This child starts after `Streamix.Repo` and before Oban. At that point no
  local queue can be executing work yet, so any row still marked `executing`
  belongs to the previous container. Retryable rows become `available`;
  exhausted rows become `discarded`, matching Oban Lifeline semantics.

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
      {:ok, %{available: 0, discarded: 0}} ->
        :ok

      {:ok, counts} ->
        Logger.warning(
          "[ObanStartupRecovery] recovered #{counts.available} jobs; " <>
            "discarded #{counts.discarded} exhausted jobs"
        )

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
  @spec recover() ::
          {:ok, %{available: non_neg_integer(), discarded: non_neg_integer()}}
          | {:error, term()}
  def recover do
    now = DateTime.utc_now()

    Repo.transaction(fn ->
      {available, _} =
        Oban.Job
        |> where([job], job.state == "executing" and job.attempt < job.max_attempts)
        |> Repo.update_all(set: [state: "available"])

      {discarded, _} =
        Oban.Job
        |> where([job], job.state == "executing" and job.attempt >= job.max_attempts)
        |> Repo.update_all(set: [state: "discarded", discarded_at: now])

      %{available: available, discarded: discarded}
    end)
  end
end
