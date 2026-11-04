defmodule StreamixWeb.Billing.FormattingTest do
  use ExUnit.Case, async: true
  alias StreamixWeb.Billing.Formatting

  test "respects the stored currency and preserves each surface's missing-value policy" do
    assert Formatting.format_price(123_456, "BRL") == "R$ 1.234,56"
    assert Formatting.format_price(123_456, "USD", missing: "-") == "US$ 1.234,56"
    assert Formatting.format_price(-105, "EUR") == "-€ 1,05"
    assert Formatting.format_price(nil, "USD") == "US$ 0,00"
    assert Formatting.format_price(nil, "USD", missing: "-") == "-"
  end
end
