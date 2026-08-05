defmodule StreamixWeb.Helpers.ParamsTest do
  use ExUnit.Case, async: true

  alias StreamixWeb.Helpers.Params

  test "bounded_integer parses exact values and clamps both edges" do
    assert Params.bounded_integer("7", 3, 1, 10) == 7
    assert Params.bounded_integer("-1", 3, 1, 10) == 1
    assert Params.bounded_integer(99, 3, 1, 10) == 10
    assert Params.bounded_integer("7junk", 3, 1, 10) == 3
  end

  test "bounded_float rejects partial values and clamps the result" do
    assert Params.bounded_float("0.75", 0.5, 0.0, 1.0) == 0.75
    assert Params.bounded_float("-2.0", 0.5, 0.0, 1.0) == 0.0
    assert Params.bounded_float(3, 0.5, 0.0, 1.0) == 1.0
    assert Params.bounded_float("0.7x", 0.5, 0.0, 1.0) == 0.5
  end

  test "strict scalar parsers reject partial and negative values" do
    assert Params.parse_non_negative_integer("0") == {:ok, 0}
    assert Params.parse_non_negative_integer(42) == {:ok, 42}
    assert Params.parse_non_negative_integer("42ms") == :error
    assert Params.parse_non_negative_integer(-1) == :error

    assert Params.parse_boolean(true, false) == {:ok, true}
    assert Params.parse_boolean("false", true) == {:ok, false}
    assert Params.parse_boolean(nil, true) == {:ok, true}
    assert Params.parse_boolean(1, false) == :error
  end
end
