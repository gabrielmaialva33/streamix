defmodule Streamix.Iptv.Sync.ValueParser do
  @moduledoc """
  Value parsing helpers used by IPTV sync pipelines.
  """

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
  Converts a value to string or returns nil.
  """
  def to_string_or_nil(nil), do: nil
  def to_string_or_nil(val), do: to_string(val)

  @max_source_ids 32

  @doc """
  Extracts the source ids of an item's `sources` array, in order.

  Each entry names its `source_id`, or only a URL carrying `?source=N`.
  Duplicates and unusable entries are dropped; `nil` when nothing remains,
  so an item without sources keeps a NULL column.
  """
  def parse_source_ids(sources) when is_list(sources) do
    sources
    |> Enum.map(&source_id/1)
    |> Enum.filter(&(is_integer(&1) and &1 > 0))
    |> Enum.uniq()
    |> Enum.take(@max_source_ids)
    |> case do
      [] -> nil
      ids -> ids
    end
  end

  def parse_source_ids(_sources), do: nil

  defp source_id(%{"source_id" => id}) when not is_nil(id), do: parse_int(id)

  defp source_id(%{"url" => url}) when is_binary(url) do
    with %URI{query: query} when is_binary(query) <- URI.parse(url),
         %{"source" => id} <- URI.decode_query(query) do
      parse_int(id)
    else
      _ -> nil
    end
  end

  defp source_id(_entry), do: nil
end
