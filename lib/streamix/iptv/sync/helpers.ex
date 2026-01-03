defmodule Streamix.Iptv.Sync.Helpers do
  @moduledoc """
  Shared helper functions for sync operations.
  Provides parsing utilities and category lookup building.
  """

  import Ecto.Query, warn: false

  alias Streamix.Iptv.Category
  alias Streamix.Repo

  @batch_size 500

  def batch_size, do: @batch_size

  @doc """
  Builds a lookup map of external_id -> database id for categories.
  """
  def build_category_lookup(provider_id, type) do
    Category
    |> where(provider_id: ^provider_id, type: ^type)
    |> select([c], {c.external_id, c.id})
    |> Repo.all()
    |> Map.new()
  end

  @doc """
  Parses a year value from various input types.
  """
  def parse_year(nil), do: nil
  def parse_year(year) when is_integer(year), do: year

  def parse_year(year) when is_binary(year) do
    case Integer.parse(year) do
      {y, _} -> y
      :error -> nil
    end
  end

  @doc """
  Parses a decimal value from various input types.
  """
  def parse_decimal(nil), do: nil
  def parse_decimal(n) when is_number(n), do: Decimal.from_float(n / 1)

  def parse_decimal(s) when is_binary(s) do
    case Float.parse(s) do
      {f, _} -> Decimal.from_float(f)
      :error -> nil
    end
  end

  @doc """
  Parses an integer value from various input types.
  """
  def parse_int(nil), do: nil
  def parse_int(n) when is_integer(n), do: n

  def parse_int(s) when is_binary(s) do
    case Integer.parse(s) do
      {i, _} -> i
      :error -> nil
    end
  end

  @doc """
  Parses a date from ISO8601 string.
  """
  def parse_date(nil), do: nil

  def parse_date(date_str) when is_binary(date_str) do
    case Date.from_iso8601(date_str) do
      {:ok, date} -> date
      {:error, _} -> nil
    end
  end

  @doc """
  Normalizes backdrop paths to a list format.
  """
  def normalize_backdrop(nil), do: nil
  def normalize_backdrop(list) when is_list(list), do: list
  def normalize_backdrop(str) when is_binary(str), do: [str]

  @doc """
  Converts a value to string or returns nil.
  """
  def to_string_or_nil(nil), do: nil
  def to_string_or_nil(val), do: to_string(val)
end
