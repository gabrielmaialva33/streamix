defmodule Streamix.Workers.EnsureAiCollectionsWorkerTest do
  use ExUnit.Case, async: false

  alias Streamix.Workers.EnsureAiCollectionsWorker

  defmodule AIStub do
    def ensure_vector_collections do
      send(
        Application.fetch_env!(:streamix, :ensure_ai_collections_test_pid),
        :ensure_vector_collections
      )

      Application.fetch_env!(:streamix, :ensure_ai_collections_result)
    end
  end

  setup do
    keys = [
      :ensure_ai_collections_ai_module,
      :ensure_ai_collections_test_pid,
      :ensure_ai_collections_result
    ]

    previous = Map.new(keys, &{&1, Application.get_env(:streamix, &1)})

    Application.put_env(:streamix, :ensure_ai_collections_ai_module, AIStub)
    Application.put_env(:streamix, :ensure_ai_collections_test_pid, self())
    Application.put_env(:streamix, :ensure_ai_collections_result, :ok)

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> Application.delete_env(:streamix, key)
        {key, value} -> Application.put_env(:streamix, key, value)
      end)
    end)

    :ok
  end

  test "creates required collections when vector search is configured" do
    assert :ok = EnsureAiCollectionsWorker.perform(%Oban.Job{})
    assert_receive :ensure_vector_collections
  end

  test "returns setup failures so Oban retries them" do
    Application.put_env(:streamix, :ensure_ai_collections_result, {:error, :unavailable})

    assert {:error, :unavailable} =
             EnsureAiCollectionsWorker.perform(%Oban.Job{})

    assert_receive :ensure_vector_collections
  end

  test "skips bootstrap when vector search is intentionally disabled" do
    Application.put_env(:streamix, :ensure_ai_collections_result, {:ok, :disabled})

    assert :ok = EnsureAiCollectionsWorker.perform(%Oban.Job{})
    assert_receive :ensure_vector_collections
  end

  test "deduplicates incomplete startup jobs and allows a fresh job after completion" do
    changeset = EnsureAiCollectionsWorker.new(%{})

    assert changeset.changes.unique.period == :infinity
    assert changeset.changes.unique.fields == [:worker]

    assert changeset.changes.unique.states == [
             :suspended,
             :available,
             :scheduled,
             :executing,
             :retryable
           ]
  end
end
