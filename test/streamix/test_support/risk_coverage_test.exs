defmodule Streamix.TestSupport.RiskCoverageTest do
  use ExUnit.Case, async: true

  alias Streamix.TestSupport.RiskCoverage

  test "calculates unique executable lines and lets coverage win duplicate entries" do
    results = [
      {{__MODULE__, 0}, {0, 1}},
      {{__MODULE__, 10}, {0, 1}},
      {{__MODULE__, 10}, {1, 0}},
      {{__MODULE__, 11}, {1, 0}},
      {{__MODULE__, 12}, {0, 1}},
      {{OtherModule, 10}, {1, 0}}
    ]

    assert_in_delta RiskCoverage.percentage_for(results, __MODULE__), 66.67, 0.01
    assert RiskCoverage.percentage_for(results, OtherModule) == 100.0
    assert RiskCoverage.percentage_for(results, MissingModule) == :missing
  end

  test "pins floors for the highest-blast-radius boundaries" do
    floors = Map.new(RiskCoverage.floors())

    assert floors[StreamixWeb.StreamToken] >= 95.0
    assert floors[Streamix.Crypto] >= 90.0
    assert floors[Streamix.Billing] >= 75.0
    assert floors[Streamix.Torrent.StatsRefresher] >= 70.0
  end
end
