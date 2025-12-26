defmodule Streamix.Iptv.Parser do
  @moduledoc """
  Stream-based parser for M3U/M3U8 playlist files.
  Optimized for large playlists (10k+ channels) with constant memory usage.
  """

  @attr_regex ~r/(\w+[-\w]*)="([^"]*)"/

  @type channel :: %{
          name: String.t(),
          logo_url: String.t() | nil,
          stream_url: String.t(),
          tvg_id: String.t() | nil,
          tvg_name: String.t() | nil,
          group_title: String.t() | nil
        }

  @doc """
  Parses M3U content using streams for memory efficiency.
  Returns a lazy stream of channels - call Enum.to_list/1 to materialize.

  ## Example

      iex> content = \"\"\"
      ...> #EXTM3U
      ...> #EXTINF:-1 tvg-id="ch1" group-title="News",Channel 1
      ...> http://stream.url/1.ts
      ...> \"\"\"
      iex> Streamix.Iptv.Parser.parse(content) |> Enum.to_list()
      [%{name: "Channel 1", stream_url: "http://stream.url/1.ts", ...}]
  """
  @spec parse(String.t()) :: Enumerable.t()
  def parse(content) when is_binary(content) do
    content
    |> String.splitter("\n", trim: true)
    |> parse_stream()
  end

  @doc """
  Parses a stream of lines into channels.
  Uses a state machine with constant memory overhead.
  """
  @spec parse_stream(Enumerable.t()) :: Enumerable.t()
  def parse_stream(lines) do
    lines
    |> Stream.map(&String.trim/1)
    |> Stream.transform(nil, &parse_line/2)
  end

  # State machine: nil = waiting for EXTINF, extinf_line = waiting for URL
  defp parse_line(line, nil) do
    if String.starts_with?(line, "#EXTINF:") do
      {[], line}
    else
      {[], nil}
    end
  end

  defp parse_line(line, extinf_line) when is_binary(extinf_line) do
    cond do
      # Another EXTINF - previous one had no URL, start fresh
      String.starts_with?(line, "#EXTINF:") ->
        {[], line}

      # Skip other directives
      String.starts_with?(line, "#") ->
        {[], extinf_line}

      # Got URL - emit channel
      valid_url?(line) ->
        channel = build_channel(extinf_line, line)
        {[channel], nil}

      # Invalid line, reset
      true ->
        {[], nil}
    end
  end

  defp build_channel(extinf_line, url) do
    attrs = extract_attributes(extinf_line)

    %{
      name: extract_name(extinf_line),
      logo_url: Map.get(attrs, "tvg-logo"),
      stream_url: url,
      tvg_id: Map.get(attrs, "tvg-id"),
      tvg_name: Map.get(attrs, "tvg-name"),
      group_title: Map.get(attrs, "group-title")
    }
  end

  defp extract_attributes(line) do
    @attr_regex
    |> Regex.scan(line)
    |> Map.new(fn [_, key, value] -> {key, value} end)
  end

  defp extract_name(line) do
    # Find content after #EXTINF:N and extract name after last comma
    case Regex.run(~r/#EXTINF:-?\d+\s*(.*)$/, line) do
      [_, rest] ->
        case :binary.match(rest, ",") do
          {pos, _} ->
            rest |> binary_part(pos + 1, byte_size(rest) - pos - 1) |> String.trim()

          :nomatch ->
            String.trim(rest)
        end

      _ ->
        "Unknown"
    end
  end

  defp valid_url?(url) do
    String.starts_with?(url, "http://") or String.starts_with?(url, "https://")
  end

  @doc """
  Fetches and parses M3U playlist from a provider URL.
  Returns a materialized list of channels.
  """
  @spec fetch_and_parse(String.t(), String.t(), String.t()) :: {:ok, [channel()]} | {:error, term()}
  def fetch_and_parse(base_url, username, password) do
    url = build_url(base_url, username, password)

    case Req.get(url, receive_timeout: 120_000) do
      {:ok, %{status: 200, body: body}} ->
        channels = body |> parse() |> Enum.to_list()
        {:ok, channels}

      {:ok, %{status: status}} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_url(base_url, username, password) do
    base_url = String.trim_trailing(base_url, "/")
    "#{base_url}/get.php?username=#{username}&password=#{password}&type=m3u_plus&output=ts"
  end

  @doc """
  Groups channels by their group_title.
  """
  @spec group_by_category([channel()]) :: %{String.t() => [channel()]}
  def group_by_category(channels) do
    Enum.group_by(channels, & &1.group_title)
  end

  @doc """
  Returns unique categories from a stream of channels.
  Memory efficient - processes stream without materializing.
  """
  @spec get_categories(Enumerable.t()) :: [String.t()]
  def get_categories(channels) do
    channels
    |> Stream.map(& &1.group_title)
    |> Stream.uniq()
    |> Stream.reject(&is_nil/1)
    |> Enum.sort()
  end
end
