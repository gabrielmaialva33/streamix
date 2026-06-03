defmodule Streamix.Gindex.Url do
  @moduledoc """
  URL helpers for GIndex worker paths.
  """

  def join(base_url, path) do
    base = String.trim_trailing(base_url, "/")
    path_part = if String.starts_with?(path, "/"), do: path, else: "/" <> path

    if String.contains?(path_part, "?") do
      base <> path_part
    else
      base <> encode_path(path_part)
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
end
