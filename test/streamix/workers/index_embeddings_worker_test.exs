defmodule Streamix.Workers.IndexEmbeddingsWorkerTest do
  use ExUnit.Case, async: false

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

  test "sets up collections before indexing movies and series" do
    assert IndexEmbeddingsWorker.perform(%Oban.Job{args: %{}}) == :ok

    assert_receive :setup
    assert_receive {:movies, nil}
    assert_receive {:series, nil}
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

    def index_all_movies(provider_id) do
      report({:movies, provider_id})
      result(:movies, {:ok, 2})
    end

    def index_all_series(provider_id) do
      report({:series, provider_id})
      result(:series, {:ok, 3})
    end

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
