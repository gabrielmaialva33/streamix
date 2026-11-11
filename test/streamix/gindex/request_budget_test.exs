defmodule Streamix.Gindex.RequestBudgetTest do
  use ExUnit.Case, async: true

  alias Streamix.Gindex.RequestBudget

  test "outside a slice every request is allowed" do
    assert RequestBudget.consume() == :ok
    assert RequestBudget.current_count() == 0
  end

  test "a slice ends at its request ceiling" do
    RequestBudget.run(2, fn ->
      assert RequestBudget.consume() == :ok
      assert RequestBudget.consume() == :ok
      assert RequestBudget.consume() == {:error, {:slice_exhausted, 2}}
    end)

    # The ceiling belongs to the slice, not to the process.
    assert RequestBudget.consume() == :ok
  end

  test "a slice also ends once its deadline has passed" do
    RequestBudget.run(
      100,
      fn ->
        assert RequestBudget.consume() == {:error, {:slice_exhausted, 0}}
      end,
      deadline_ms: 0
    )

    RequestBudget.run(
      100,
      fn ->
        assert RequestBudget.consume() == :ok
        assert RequestBudget.current_count() == 1
      end,
      deadline_ms: :timer.minutes(90)
    )
  end

  test "nested slices restore the outer one" do
    RequestBudget.run(5, fn ->
      :ok = RequestBudget.consume()
      RequestBudget.run(1, fn -> :ok = RequestBudget.consume() end)
      assert RequestBudget.current_count() == 1
    end)
  end
end
