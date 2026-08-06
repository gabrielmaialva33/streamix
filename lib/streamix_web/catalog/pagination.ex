defmodule StreamixWeb.Catalog.Pagination do
  @moduledoc false

  @max_offset 100_000

  @spec max_offset() :: non_neg_integer()
  def max_offset, do: @max_offset

  @spec metadata(non_neg_integer(), non_neg_integer(), pos_integer(), non_neg_integer()) :: map()
  def metadata(item_count, total, limit, offset) do
    candidate_next = offset + item_count

    has_more? =
      item_count > 0 and candidate_next < total and candidate_next <= @max_offset

    %{
      limit: limit,
      offset: offset,
      total: total,
      has_more: has_more?,
      next_offset: if(has_more?, do: candidate_next, else: nil)
    }
  end
end
