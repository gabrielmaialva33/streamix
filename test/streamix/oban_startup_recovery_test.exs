defmodule Streamix.ObanStartupRecoveryTest do
  use Streamix.DataCase, async: false

  use Oban.Testing, repo: Streamix.Repo

  alias Streamix.ObanStartupRecovery
  alias Streamix.Repo

  defmodule RecoveryWorker do
    use Oban.Worker

    @impl Oban.Worker
    def perform(_job), do: :ok
  end

  test "retries orphaned jobs and discards exhausted ones before queues start" do
    retryable = insert_job!("retryable")
    exhausted = insert_job!("exhausted")
    untouched = insert_job!("untouched")

    mark_executing(retryable.id, attempt: 1, max_attempts: 3)
    mark_executing(exhausted.id, attempt: 3, max_attempts: 3)

    assert {:ok, %{available: 1, discarded: 1}} = ObanStartupRecovery.recover()

    assert %{state: "available"} = Repo.get!(Oban.Job, retryable.id)
    assert %{state: "discarded", discarded_at: %DateTime{}} = Repo.get!(Oban.Job, exhausted.id)
    assert %{state: "available", attempt: 0} = Repo.get!(Oban.Job, untouched.id)
  end

  defp insert_job!(kind) do
    {:ok, job} =
      %{"kind" => kind}
      |> RecoveryWorker.new()
      |> Oban.insert()

    job
  end

  defp mark_executing(job_id, attrs) do
    Oban.Job
    |> where([job], job.id == ^job_id)
    |> Repo.update_all(
      set: [
        state: "executing",
        attempt: Keyword.fetch!(attrs, :attempt),
        max_attempts: Keyword.fetch!(attrs, :max_attempts),
        attempted_at: DateTime.utc_now()
      ]
    )
  end
end
