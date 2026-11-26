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

  test "a rejected title is isolated and left out; the rest of its batch is indexed" do
    contents = Enum.map(1..10, &%{id: &1, title: "Content #{&1}", provider_id: 1})
    test_pid = self()

    rejection =
      {:api_error, 422,
       %{"error" => %{"message" => "input rejected by content safety screening"}}}

    batch_indexer = fn batch, _collection ->
      ids = Enum.map(batch, & &1.id)
      if 7 in ids, do: {:error, rejection}, else: {:ok, length(ids)}
    end

    assert SemanticSearch.index_contents(contents, :movies,
             batch_indexer: batch_indexer,
             on_rejected: fn content, collection ->
               send(test_pid, {:rejected, collection, content.id})
             end,
             on_batch: fn last_id, count ->
               send(test_pid, {:checkpoint, last_id, count})
               :ok
             end,
             rate_limit_delay: 0
           ) == {:ok, 9}

    assert_received {:rejected, :movies, 7}
    refute_received {:rejected, _, _}
    assert_received {:checkpoint, 10, 9}
  end

  test "a failure that is not a rejected input still stops the run" do
    contents = Enum.map(1..4, &%{id: &1, title: "Content #{&1}", provider_id: 1})

    assert SemanticSearch.index_contents(contents, :movies,
             batch_indexer: fn _batch, _collection -> {:error, {:api_error, 500, %{}}} end,
             on_rejected: fn _content, _collection -> flunk("not a rejected input") end,
             rate_limit_delay: 0
           ) == {:error, {:batch_failed, :movies, 0, {:api_error, 500, %{}}}}
  end

  test "prune_stale deletes the points no indexed title owns" do
    test_pid = self()

    assert SemanticSearch.prune_stale(:animes,
             live_ids: [1, 2, 3],
             point_ids: fn "animes" -> {:ok, [1, 2, 3, 40, 50]} end,
             delete_points: fn name, ids ->
               send(test_pid, {:deleted, name, ids})
               :ok
             end
           ) == {:ok, 2}

    assert_received {:deleted, "animes", [40, 50]}
  end

  test "prune_stale deletes nothing when the catalog read comes back empty" do
    assert SemanticSearch.prune_stale(:movies,
             live_ids: [],
             point_ids: fn _ -> flunk("must not list points") end,
             delete_points: fn _, _ -> flunk("must not delete") end
           ) == {:error, :no_documents}
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
