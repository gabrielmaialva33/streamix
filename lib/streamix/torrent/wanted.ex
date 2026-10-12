defmodule Streamix.Torrent.Wanted do
  @moduledoc """
  A catalog movie the targeted search should look for.

      %{tmdb_id: "1003469", imdb_id: "tt18559372", year: 2022,
        title: "Combinação do Azevinho", original_title: nil}

  `tmdb_id` is required, plus a `title` or an `imdb_id`. `imdb_id` (`tt…`)
  and `year` make the match much safer: without the IMDb id only a title +
  year match is possible, and without a year nothing can match by title.

  The BR sites cannot search by IMDb id, so an entry with an IMDb id but no
  title is accepted and reported as unsearchable by the targeted search.

  Wanted lists travel through Oban job args, so `to_args/1` / `new/1` round
  trip through string-keyed maps.
  """

  @type t :: %{
          tmdb_id: String.t(),
          imdb_id: String.t() | nil,
          year: integer() | nil,
          title: String.t() | nil,
          original_title: String.t() | nil
        }

  @doc "Validates and normalizes one wanted entry (atom or string keys)."
  @spec new(map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_map(attrs) do
    with {:ok, tmdb_id} <- tmdb_id(fetch(attrs, :tmdb_id)),
         {:ok, imdb_id} <- imdb_id(fetch(attrs, :imdb_id)),
         {:ok, year} <- year(fetch(attrs, :year)),
         {:ok, title} <- title(fetch(attrs, :title), imdb_id) do
      {:ok,
       %{
         tmdb_id: tmdb_id,
         imdb_id: imdb_id,
         year: year,
         title: title,
         original_title: optional_text(fetch(attrs, :original_title))
       }}
    end
  end

  def new(_attrs), do: {:error, :invalid_wanted}

  @doc "Normalizes a list, failing on the first invalid entry (with its index)."
  @spec new_list([map()]) :: {:ok, [t()]} | {:error, {:invalid_wanted, non_neg_integer(), term()}}
  def new_list(list) when is_list(list) do
    list
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {attrs, index}, {:ok, acc} ->
      case new(attrs) do
        {:ok, wanted} -> {:cont, {:ok, [wanted | acc]}}
        {:error, reason} -> {:halt, {:error, {:invalid_wanted, index, reason}}}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, acc |> Enum.reverse() |> Enum.uniq_by(& &1.tmdb_id)}
      error -> error
    end
  end

  @doc "String-keyed map for Oban job args."
  @spec to_args(t()) :: map()
  def to_args(wanted) do
    wanted
    |> Map.take([:tmdb_id, :imdb_id, :year, :title, :original_title])
    |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
  end

  @doc """
  Parses `tmdb_id,imdb_id,year,title` CSV (no quoting needed; extra commas
  belong to the title). A header line and blank lines are ignored; `imdb_id`
  and `year` may be empty.
  """
  @spec parse_csv(String.t()) :: {:ok, [t()]} | {:error, {:invalid_line, pos_integer(), term()}}
  def parse_csv(content) when is_binary(content) do
    content
    |> String.replace_prefix("﻿", "")
    |> String.split(~r/\r?\n/)
    |> Enum.with_index(1)
    |> Enum.reject(fn {line, number} ->
      String.trim(line) == "" or (number == 1 and header?(line))
    end)
    |> Enum.reduce_while({:ok, []}, fn {line, number}, {:ok, acc} ->
      case parse_line(line) do
        {:ok, wanted} -> {:cont, {:ok, [wanted | acc]}}
        {:error, reason} -> {:halt, {:error, {:invalid_line, number, reason}}}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, acc |> Enum.reverse() |> Enum.uniq_by(& &1.tmdb_id)}
      error -> error
    end
  end

  @doc "Reads and parses a CSV file (see `parse_csv/1`)."
  @spec read_csv(Path.t()) :: {:ok, [t()]} | {:error, term()}
  def read_csv(path) do
    with {:ok, content} <- File.read(path), do: parse_csv(content)
  end

  defp parse_line(line) do
    case String.split(line, ",", parts: 4) do
      [tmdb_id, imdb_id, year, title] ->
        new(%{
          tmdb_id: unquote_field(tmdb_id),
          imdb_id: unquote_field(imdb_id),
          year: unquote_field(year),
          title: unquote_field(title)
        })

      _ ->
        {:error, :expected_four_columns}
    end
  end

  defp header?(line), do: not Regex.match?(~r/^\s*"?\d/, line)

  defp unquote_field(value) do
    value |> String.trim() |> String.trim("\"") |> String.trim()
  end

  defp fetch(attrs, key), do: Map.get(attrs, key, Map.get(attrs, Atom.to_string(key)))

  defp tmdb_id(value) when is_integer(value) and value > 0, do: {:ok, Integer.to_string(value)}

  defp tmdb_id(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {id, ""} when id > 0 -> {:ok, Integer.to_string(id)}
      _ -> {:error, :invalid_tmdb_id}
    end
  end

  defp tmdb_id(_value), do: {:error, :invalid_tmdb_id}

  defp imdb_id(value) when value in [nil, ""], do: {:ok, nil}

  defp imdb_id(value) when is_binary(value) do
    value = value |> String.trim() |> String.downcase()

    cond do
      value == "" -> {:ok, nil}
      Regex.match?(~r/^tt\d{5,12}$/, value) -> {:ok, value}
      true -> {:error, :invalid_imdb_id}
    end
  end

  defp imdb_id(_value), do: {:error, :invalid_imdb_id}

  defp year(value) when value in [nil, ""], do: {:ok, nil}
  defp year(value) when is_integer(value) and value in 1880..2100, do: {:ok, value}

  defp year(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {year, ""} -> year(year)
      _ -> if String.trim(value) == "", do: {:ok, nil}, else: {:error, :invalid_year}
    end
  end

  defp year(_value), do: {:error, :invalid_year}

  defp title(value, imdb_id) do
    case optional_text(value) do
      nil when is_nil(imdb_id) -> {:error, :missing_title}
      title -> {:ok, title}
    end
  end

  defp optional_text(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      text -> text
    end
  end

  defp optional_text(_value), do: nil
end
