defmodule Streamix.AI.SemanticSearchTest do
  use ExUnit.Case, async: true

  alias Streamix.AI.SemanticSearch

  test "index_contents stops after the first failed batch and reports prior progress" do
    contents =
      Enum.map(1..25, fn id ->
        %{id: id, title: "Content #{id}", provider_id: 1}
      end)

    test_pid = self()

    batch_indexer = fn batch, collection ->
      send(test_pid, {:batch, collection, Enum.map(batch, & &1.id)})

      case hd(batch).id do
        1 -> {:ok, length(batch)}
        11 -> {:error, :provider_unavailable}
      end
    end

    assert SemanticSearch.index_contents(contents, :movies,
             batch_indexer: batch_indexer,
             rate_limit_delay: 0
           ) ==
             {:error, {:batch_failed, :movies, 10, :provider_unavailable}}

    first_batch_ids = Enum.to_list(1..10)
    second_batch_ids = Enum.to_list(11..20)
    third_batch_ids = Enum.to_list(21..25)

    assert_received {:batch, :movies, ^first_batch_ids}
    assert_received {:batch, :movies, ^second_batch_ids}
    refute_received {:batch, :movies, ^third_batch_ids}
  end
end
