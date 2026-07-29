defmodule Streamix.AI.SemanticSearchTest do
  use Streamix.DataCase, async: true

  alias Streamix.AI.SemanticSearch

  import Streamix.AccountsFixtures
  import Streamix.IptvFixtures

  test "index_contents stops after the first failed batch and reports prior progress" do
    contents =
      Enum.map(1..130, fn id ->
        %{id: id, title: "Content #{id}", provider_id: 1}
      end)

    test_pid = self()

    batch_indexer = fn batch, collection ->
      send(test_pid, {:batch, collection, Enum.map(batch, & &1.id)})

      case hd(batch).id do
        1 -> {:ok, length(batch)}
        65 -> {:error, :provider_unavailable}
      end
    end

    assert SemanticSearch.index_contents(contents, :movies,
             batch_indexer: batch_indexer,
             on_batch: fn last_id, count ->
               send(test_pid, {:checkpoint, last_id, count})
               :ok
             end,
             rate_limit_delay: 0
           ) ==
             {:error, {:batch_failed, :movies, 64, :provider_unavailable}}

    first_batch_ids = Enum.to_list(1..64)
    second_batch_ids = Enum.to_list(65..128)
    third_batch_ids = Enum.to_list(129..130)

    assert_received {:batch, :movies, ^first_batch_ids}
    assert_received {:batch, :movies, ^second_batch_ids}
    assert_received {:checkpoint, 64, 64}
    refute_received {:checkpoint, 128, _}
    refute_received {:batch, :movies, ^third_batch_ids}
  end

  test "index_all_movies resumes after a stable database id" do
    user = user_fixture()
    provider = provider_fixture(user)
    first = movie_fixture(provider, %{title: "First"})
    second = movie_fixture(provider, %{title: "Second"})
    test_pid = self()

    batch_indexer = fn batch, collection ->
      send(test_pid, {:batch, collection, Enum.map(batch, & &1.id)})
      {:ok, length(batch)}
    end

    assert {:ok, 1} =
             SemanticSearch.index_all_movies(provider.id,
               after_id: first.id,
               batch_indexer: batch_indexer,
               rate_limit_delay: 0
             )

    assert_received {:batch, :movies, [second_id]}
    assert second_id == second.id
  end
end
