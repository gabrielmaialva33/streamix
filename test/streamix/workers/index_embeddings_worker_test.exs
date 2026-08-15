defmodule Streamix.Workers.IndexEmbeddingsWorkerTest do
  use Streamix.DataCase, async: false

  alias Streamix.Repo
  alias Streamix.Workers.IndexEmbeddingsWorker

  setup do
    prior_module = Application.get_env(:streamix, :semantic_search_module)
    prior_pid = Application.get_env(:streamix, :index_embeddings_test_pid)
    prior_results = Application.get_env(:streamix, :index_embeddings_test_results)

    Application.put_env(:streamix, :semantic_search_module, __MODULE__.SemanticSearchStub)
    Application.put_env(:streamix, :index_embeddings_test_pid, self())
    Application.put_env(:streamix, :index_embeddings_test_results, %{})

    on_exit(fn ->
      restore_env(:semantic_search_module, prior_module)
      restore_env(:index_embeddings_test_pid, prior_pid)
      restore_env(:index_embeddings_test_results, prior_results)
    end)

    :ok
  end

  test "sets up collections before indexing movies, series and animes" do
    assert IndexEmbeddingsWorker.perform(%Oban.Job{args: %{}}) == :ok

    assert_receive :setup
    assert_receive {:movies, nil}
    assert_receive {:series, nil}
    assert_receive {:animes, nil}
  end

  test "indexes only animes when the job asks for that collection" do
    assert IndexEmbeddingsWorker.perform(%Oban.Job{args: %{"collection" => "animes"}}) == :ok

    assert_receive :setup
    assert_receive {:animes, nil}
    refute_receive {:movies, _}
    refute_receive {:series, _}
  end

  test "resumes directly from a persisted anime checkpoint" do
    job = %Oban.Job{
      args: %{},
      meta: %{
        "checkpoint_collection" => "animes",
        "checkpoint_after_id" => 77
      }
    }

    assert :ok = IndexEmbeddingsWorker.perform(job)

    assert_receive :setup
    assert_receive {:animes_after_id, 77}
    refute_receive {:movies, _}
    refute_receive {:series, _}
  end

  test "stops before animes when series indexing fails" do
    set_results(%{series: {:error, :embedding_provider_unavailable}})

    assert IndexEmbeddingsWorker.perform(%Oban.Job{args: %{}}) ==
             {:error, :embedding_provider_unavailable}

    assert_receive {:series, nil}
    refute_receive {:animes, _}
  end

  test "returns setup errors without attempting to index" do
    set_results(%{setup: {:error, :qdrant_unavailable}})

    assert IndexEmbeddingsWorker.perform(%Oban.Job{args: %{}}) ==
             {:error, {:setup_failed, :qdrant_unavailable}}

    assert_receive :setup
    refute_receive {:movies, _}
    refute_receive {:series, _}
  end

  test "stops before series when movie indexing fails" do
    set_results(%{movies: {:error, :embedding_provider_unavailable}})

    assert IndexEmbeddingsWorker.perform(%Oban.Job{args: %{}}) ==
             {:error, :embedding_provider_unavailable}

    assert_receive :setup
    assert_receive {:movies, nil}
    refute_receive {:series, _}
  end

  test "allows long backfills but stays below the Lifeline threshold" do
    assert IndexEmbeddingsWorker.timeout(%Oban.Job{}) == :timer.minutes(150)
  end

  test "resumes directly from a persisted series checkpoint" do
    job = %Oban.Job{
      args: %{},
      meta: %{
        "checkpoint_collection" => "series",
        "checkpoint_after_id" => 42
      }
    }

    assert :ok = IndexEmbeddingsWorker.perform(job)

    assert_receive :setup
    refute_receive {:movies, _}
    assert_receive {:series, nil}
    assert_receive {:series_after_id, 42}
    # Resuming mid-run still carries on into the collections that follow.
    assert_receive {:animes, nil}
  end

  test "persists the last successful content id in Oban metadata" do
    job =
      %{"collection" => "movies"}
      |> IndexEmbeddingsWorker.new()
      |> Oban.insert!()

    assert :ok = IndexEmbeddingsWorker.perform(job)

    checkpoint = Repo.get!(Oban.Job, job.id).meta
    assert checkpoint["checkpoint_collection"] == "movies"
    assert checkpoint["checkpoint_after_id"] == 101
  end

  defp set_results(results) do
    Application.put_env(:streamix, :index_embeddings_test_results, results)
  end

  defp restore_env(key, nil), do: Application.delete_env(:streamix, key)
  defp restore_env(key, value), do: Application.put_env(:streamix, key, value)

  defmodule SemanticSearchStub do
    @moduledoc false

    def setup do
      report(:setup)
      result(:setup, :ok)
    end

    def index_all_movies(provider_id, opts) do
      report({:movies, provider_id})
      report({:movies_after_id, Keyword.fetch!(opts, :after_id)})
      maybe_checkpoint(:movies, opts, result(:movies, {:ok, 2}))
    end

    def index_all_series(provider_id, opts) do
      report({:series, provider_id})
      report({:series_after_id, Keyword.fetch!(opts, :after_id)})
      maybe_checkpoint(:series, opts, result(:series, {:ok, 3}))
    end

    def index_all_animes(provider_id, opts) do
      report({:animes, provider_id})
      report({:animes_after_id, Keyword.fetch!(opts, :after_id)})
      maybe_checkpoint(:animes, opts, result(:animes, {:ok, 4}))
    end

    @checkpoint_ids %{movies: 101, series: 202, animes: 303}

    defp maybe_checkpoint(collection, opts, {:ok, _count} = result) do
      :ok = Keyword.fetch!(opts, :on_batch).(@checkpoint_ids[collection], 1)
      result
    end

    defp maybe_checkpoint(_collection, _opts, result), do: result

    defp report(message) do
      send(Application.fetch_env!(:streamix, :index_embeddings_test_pid), message)
    end

    defp result(key, default) do
      :streamix
      |> Application.fetch_env!(:index_embeddings_test_results)
      |> Map.get(key, default)
    end
  end
end
