defmodule Streamix.Gindex.Url do
  @moduledoc """
  URL helpers for GIndex worker paths.
  """

  def join(base_url, path) do
    base = String.trim_trailing(base_url, "/")
    path_part = if String.starts_with?(path, "/"), do: path, else: "/" <> path

    base <> encode_path(path_part)
  end

  @doc """
  Joins an upstream-generated link while preserving its query string.

  Folder and file paths must go through `join/2`, where a literal `?` is
  encoded as part of the name. This function is only for links that already
  carry an actual query, such as `/download.aspx?file=...`.
  """
  def join_link(base_url, link) when is_binary(link) do
    case URI.parse(link) do
      %URI{scheme: scheme} when scheme in ["http", "https"] ->
        link

      %URI{path: path, query: query, fragment: fragment} ->
        joined = join(base_url, path || "")

        joined
        |> maybe_append("?", query)
        |> maybe_append("#", fragment)
    end
  end

  defp encode_path(path) do
    path
    |> String.split("/")
    |> Enum.with_index()
    |> Enum.map_join("/", fn {segment, index} ->
      if index <= 1 and Regex.match?(~r/^\d+:$/, segment) do
        segment
      else
        URI.encode(segment, &uri_char?/1)
      end
    end)
  end

  defp uri_char?(char) do
    char in ?0..?9 or char in ?a..?z or char in ?A..?Z or char in ~c"-._~!$&'()*+,;=@"
  end

  defp maybe_append(value, _separator, nil), do: value
  defp maybe_append(value, separator, suffix), do: value <> separator <> suffix
end
