defmodule StreamixWeb.Helpers.MoneyTest do
  use ExUnit.Case, async: true

  alias StreamixWeb.Helpers.Money

  doctest Money

  test "keeps the stored currency and localizes only the number" do
    assert Money.format(1000, "BRL") == "R$ 10,00"
    assert Money.format(1000, "USD") == "US$ 10,00"
    assert Money.format(1000, "EUR") == "€ 10,00"
    assert Money.format(1000, "gbp") == "GBP 10,00"
    assert Money.format(1000, nil) == "R$ 10,00"
  end

  test "groups thousands and keeps cents" do
    assert Money.format(0, "BRL") == "R$ 0,00"
    assert Money.format(5, "BRL") == "R$ 0,05"
    assert Money.format(99_999_999, "BRL") == "R$ 999.999,99"
    assert Money.format(-1999, "BRL") == "-R$ 19,99"
    assert Money.format(nil, "USD") == "US$ 0,00"
  end
end
