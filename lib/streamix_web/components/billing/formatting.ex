defmodule StreamixWeb.Billing.Formatting do
  @moduledoc "Shared currency-aware price presentation for billing surfaces."
  alias StreamixWeb.Helpers.Money

  def format_price(cents, currency, opts \\ [])

  def format_price(cents, currency, _opts) when is_integer(cents),
    do: Money.format(cents, currency)

  def format_price(cents, currency, opts) do
    case Keyword.fetch(opts, :missing) do
      {:ok, fallback} -> fallback
      :error -> Money.format(cents, currency)
    end
  end
end
