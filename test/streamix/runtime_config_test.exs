defmodule Streamix.RuntimeConfigTest do
  use ExUnit.Case, async: true

  alias Streamix.RuntimeConfig

  test "parses explicit booleans and preserves the default when unset" do
    assert RuntimeConfig.boolean!("FEATURE_FLAG", " YES ", false)
    refute RuntimeConfig.boolean!("FEATURE_FLAG", "off", true)
    assert RuntimeConfig.boolean!("FEATURE_FLAG", nil, true)
  end

  test "rejects ambiguous boolean values with the environment variable name" do
    assert_raise ArgumentError, ~r/FEATURE_FLAG.*boolean/i, fn ->
      RuntimeConfig.boolean!("FEATURE_FLAG", "sometimes", false)
    end
  end

  test "parses bounded integers and rejects malformed or out-of-range values" do
    assert RuntimeConfig.integer!("PORT", "4000", 3000, min: 1, max: 65_535) == 4_000
    assert RuntimeConfig.integer!("POOL_SIZE", nil, 10, min: 1) == 10

    assert_raise ArgumentError, ~r/PORT.*integer/i, fn ->
      RuntimeConfig.integer!("PORT", "4000oops", 3000, min: 1)
    end

    assert_raise ArgumentError, ~r/PORT.*at most 65535/i, fn ->
      RuntimeConfig.integer!("PORT", "70000", 3000, max: 65_535)
    end
  end

  test "normalizes comma-separated values and removes blanks and duplicates" do
    assert RuntimeConfig.csv(" first, ,second,first ") == ["first", "second"]
    assert RuntimeConfig.csv(nil) == []
  end
end
