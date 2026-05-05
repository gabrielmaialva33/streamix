defmodule Streamix.Iptv.Gindex.Scraper.Categories do
  @moduledoc """
  Category folder normalization for GIndex scraping.
  """

  def from_folder(item) do
    %{
      name: clean_name(item.name),
      path: item.path,
      count: extract_count(item.name)
    }
  end

  def extract_count(name) do
    case Regex.run(~r/\((\d+)\)$/, name) do
      [_, count] -> String.to_integer(count)
      nil -> nil
    end
  end

  def clean_name(name) do
    name
    |> String.replace(~r/\s*\(\d+\)$/, "")
    |> String.trim()
  end
end
