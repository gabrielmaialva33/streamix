defmodule Streamix.Iptv.M3uParser do
  @moduledoc """
  Parser for the Xtream-flavoured M3U Plus format returned by `/get.php`.

  Each entry on the wire is two lines:

      #EXTINF:-1 tvg-id="123" tvg-name="Channel" tvg-logo="https://..." group-title="Live - Esporte",Channel Name
      http://server/live/user/pass/12345.ts

  We pair them up and emit a tagged tuple per entry. The kind is derived
  from the URL segment — Xtream always serves `/live/`, `/movie/`, or
  `/series/` between credentials and the stream id, so the URL alone
  tells us which catalog the entry belongs to. Anything that doesn't
  match those three prefixes is dropped (no-op rows, providers that
  expose extra paths we don't handle).

  ## Output shape

      {:live, %{
        stream_id: 12345,
        name: "Channel Name",
        tvg_id: "123",
        tvg_name: "Channel",
        logo: "https://...",
        group_title: "Live - Esporte",
        url: "http://...",
        extension: "ts"
      }}

      {:movie, %{stream_id: ..., name: ..., extension: "mp4", ...}}
      {:episode, %{stream_id: ..., name: ..., extension: "mkv", group_title: ..., ...}}

  Stream-friendly: `parse_stream/1` takes a binary or an
  `Enumerable.t()` of binary chunks and returns a `Stream` of entries,
  so the caller can pipe it straight into batched upserts.
  """

  @type entry_kind :: :live | :movie | :episode

  @type entry ::
          {entry_kind,
           %{
             stream_id: pos_integer(),
             name: String.t(),
             tvg_id: String.t() | nil,
             tvg_name: String.t() | nil,
             logo: String.t() | nil,
             group_title: String.t() | nil,
             url: String.t(),
             extension: String.t()
           }}

  @doc """
  Parses an entire M3U body into a list of entries. Eager — convenient
  for tests and small fixtures, prefer `parse_stream/1` for production
  payloads.
  """
  @spec parse(binary()) :: [entry]
  def parse(body) when is_binary(body) do
    body
    |> parse_stream()
    |> Enum.to_list()
  end

  @doc """
  Returns a `Stream` of entries from a binary or chunked enumerable.
  """
  @spec parse_stream(binary() | Enumerable.t()) :: Enumerable.t()
  def parse_stream(body) when is_binary(body) do
    body
    |> String.split(["\r\n", "\n"], trim: false)
    |> stream_from_lines()
  end

  def parse_stream(chunks) do
    chunks
    |> Stream.transform("", &split_chunk/2)
    |> stream_from_lines()
  end

  # Internals

  defp split_chunk(chunk, leftover) when is_binary(chunk) do
    case String.split(leftover <> chunk, ["\r\n", "\n"]) do
      [partial] ->
        {[], partial}

      parts ->
        partial = List.last(parts)
        complete = Enum.drop(parts, -1)
        {complete, partial}
    end
  end

  defp stream_from_lines(lines) do
    lines
    |> Stream.map(&String.trim/1)
    |> Stream.reject(&(&1 == "" or &1 == "#EXTM3U"))
    |> Stream.chunk_while(
      nil,
      &chunk_extinf/2,
      &flush_extinf/1
    )
    |> Stream.map(&decode_entry/1)
    |> Stream.reject(&is_nil/1)
  end

  defp chunk_extinf("#EXTINF:" <> _ = line, nil), do: {:cont, {:meta, line}}
  defp chunk_extinf("#" <> _, acc), do: {:cont, acc}

  defp chunk_extinf(url_line, {:meta, meta_line}) do
    {:cont, {meta_line, url_line}, nil}
  end

  defp chunk_extinf(_orphan_url, nil), do: {:cont, nil}

  defp flush_extinf(_), do: {:cont, nil}

  defp decode_entry({meta_line, url_line}) do
    case classify_url(url_line) do
      {:ok, kind, stream_id, extension} ->
        attrs = parse_extinf(meta_line)
        {kind, Map.merge(attrs, %{stream_id: stream_id, url: url_line, extension: extension})}

      _ ->
        nil
    end
  end

  defp decode_entry(_), do: nil

  # /live/user/pass/12345.ts
  # /movie/user/pass/67890.mp4
  # /series/user/pass/11122.mkv
  defp classify_url(url) do
    case Regex.run(~r{/(live|movie|series)/[^/]+/[^/]+/(\d+)\.([a-zA-Z0-9]+)$}, url) do
      ["/" <> _, "live", id, ext] -> {:ok, :live, String.to_integer(id), ext}
      ["/" <> _, "movie", id, ext] -> {:ok, :movie, String.to_integer(id), ext}
      ["/" <> _, "series", id, ext] -> {:ok, :episode, String.to_integer(id), ext}
      _ -> :error
    end
  end

  # Splits "#EXTINF:-1 tvg-id=\"X\" tvg-name=\"Y\" ...,Display Name" into
  # the attribute map plus the trailing display name. The display name is
  # everything after the last comma on the directive line.
  defp parse_extinf(line) do
    "#EXTINF:" <> rest = line
    {_runtime, attrs_and_name} = pop_runtime(rest)

    {attrs_blob, display_name} = split_on_last_comma(attrs_and_name)

    attrs =
      attrs_blob
      |> extract_quoted_attrs()
      |> Map.put(:name, String.trim(display_name))

    %{
      tvg_id: Map.get(attrs, "tvg-id"),
      tvg_name: Map.get(attrs, "tvg-name"),
      logo: Map.get(attrs, "tvg-logo"),
      group_title: Map.get(attrs, "group-title"),
      name: attrs.name
    }
  end

  defp pop_runtime(rest) do
    case String.split(rest, " ", parts: 2) do
      [runtime, tail] -> {runtime, tail}
      [runtime] -> {runtime, ""}
    end
  end

  # The display name can contain commas, so we can't naively split on
  # the first or last comma. The reliable separator is the comma that
  # follows the closing quote of the last attribute, i.e. `",` — that
  # token only appears at the end of the attribute block.
  defp split_on_last_comma(blob) do
    case :binary.matches(blob, "\",") do
      [] ->
        # No quoted attrs at all (rare). Fall back to the FIRST comma,
        # since the display name then occupies the whole tail.
        case :binary.matches(blob, ",") do
          [] ->
            {"", blob}

          [{pos, _} | _] ->
            attrs = binary_part(blob, 0, pos)
            name = binary_part(blob, pos + 1, byte_size(blob) - pos - 1)
            {attrs, name}
        end

      matches ->
        {pos, _len} = List.last(matches)
        attrs = binary_part(blob, 0, pos + 1)
        name = binary_part(blob, pos + 2, byte_size(blob) - pos - 2)
        {attrs, name}
    end
  end

  defp extract_quoted_attrs(blob) do
    Regex.scan(~r/([a-zA-Z0-9_-]+)="([^"]*)"/, blob)
    |> Enum.reduce(%{}, fn [_, key, value], acc -> Map.put(acc, key, value) end)
  end
end
