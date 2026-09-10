defmodule Streamix.Embedplay.HLS do
  @moduledoc false

  alias Streamix.Embedplay.HTTP

  @uri_attribute ~r/(?<=[,:])([A-Z0-9-]*URI)="([^"]*)"/
  @playlist_tags ~w(#EXT-X-MEDIA: #EXT-X-I-FRAME-STREAM-INF: #EXT-X-RENDITION-REPORT:)
  @max_playlist 2 * 1024 * 1024

  def playlist?(body) when is_binary(body), do: String.starts_with?(body, "#EXTM3U")
  def playlist?(_), do: false

  def parse(body, base) when is_binary(body) and byte_size(body) <= @max_playlist do
    if String.valid?(body) and playlist?(body) and
         not String.contains?(body, ["#EXT-X-DEFINE:", "#EXT-X-CONTENT-STEERING:", "{$"]) do
      parse_lines(String.split(body, "\n"), base)
    else
      {:error, :unsupported_playlist}
    end
  end

  def parse(_, _), do: {:error, :unsupported_playlist}

  defp parse_lines(lines, base) do
    lines
    |> Enum.reduce_while({:ok, [], false}, &append_line(&1, &2, base))
    |> case do
      {:ok, lines, _} -> {:ok, lines |> Enum.reverse() |> List.flatten()}
      error -> error
    end
  end

  defp append_line(line, {:ok, acc, next_playlist?}, base) do
    line = String.trim(line)

    case parse_line(line, base, next_playlist?) do
      {:ok, nodes} ->
        next_playlist? =
          String.starts_with?(line, "#EXT-X-STREAM-INF:") or
            (next_playlist? and (line == "" or String.starts_with?(line, "#")))

        {:cont, {:ok, [nodes ++ ["\n"] | acc], next_playlist?}}

      error ->
        {:halt, error}
    end
  end

  defp parse_line("", _base, _next), do: {:ok, []}
  defp parse_line("#EXT" <> _ = line, base, _next), do: attributes(line, base)
  defp parse_line("#" <> _line, _base, _next), do: {:ok, []}

  defp parse_line(line, base, next_playlist?) do
    with {:ok, url} <- reference(base, line) do
      {:ok, [{:resource, url, if(next_playlist?, do: :playlist, else: :media)}]}
    end
  end

  defp attributes(line, base) do
    kind =
      if Enum.any?(@playlist_tags, &String.starts_with?(line, &1)), do: :playlist, else: :media

    matches = Regex.scan(@uri_attribute, line, return: :index)

    names = for [_match, {start, size}, _value] <- matches, do: binary_part(line, start, size)
    leftover = Regex.replace(@uri_attribute, line, "")

    if Regex.match?(~r/\b[A-Z0-9-]*URI\s*=/, leftover) or Enum.uniq(names) != names do
      {:error, :unsupported_playlist}
    else
      replace_attributes(line, base, kind, matches, 0, [])
    end
  end

  defp replace_attributes(line, _base, _kind, [], offset, acc) do
    {:ok, Enum.reverse([binary_part(line, offset, byte_size(line) - offset) | acc])}
  end

  defp replace_attributes(line, base, kind, [[_match, _name, {start, size}] | rest], offset, acc) do
    with {:ok, url} <- reference(base, binary_part(line, start, size)) do
      prefix = binary_part(line, offset, start - offset)

      replace_attributes(line, base, kind, rest, start + size, [
        {:resource, url, kind},
        prefix | acc
      ])
    end
  end

  defp reference(base, value) when byte_size(value) > 0 and byte_size(value) <= 8192 do
    with {:ok, url} <- HTTP.merge_url(base, value),
         {:ok, %URI{scheme: scheme, host: host, userinfo: nil}} <- URI.new(url),
         true <- scheme in ["http", "https"] and is_binary(host) do
      {:ok, url}
    else
      _ -> {:error, :unsafe_url}
    end
  end

  defp reference(_, _), do: {:error, :unsafe_url}
end
