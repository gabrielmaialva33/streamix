defmodule Streamix.AI.ScoreThresholdsTest do
  use ExUnit.Case, async: false

  alias Streamix.AI.ScoreThresholds

  test "defaults are the floors calibrated for the production embedding model" do
    assert ScoreThresholds.query() == 0.25
    assert ScoreThresholds.similar() == 0.40
    assert ScoreThresholds.profile() == 0.35
  end

  test "each floor can be overridden through config without touching the others" do
    prior = Application.get_env(:streamix, :semantic_scores)
    Application.put_env(:streamix, :semantic_scores, query: 0.3)

    on_exit(fn ->
      if prior,
        do: Application.put_env(:streamix, :semantic_scores, prior),
        else: Application.delete_env(:streamix, :semantic_scores)
    end)

    assert ScoreThresholds.query() == 0.3
    assert ScoreThresholds.similar() == 0.40
  end
end
