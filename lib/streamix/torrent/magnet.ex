defmodule Streamix.Torrent.Magnet do
  @moduledoc """
  Builds and parses BitTorrent magnet URIs.

  Sources usually hand us either a full magnet URI (gratistorrent,
  comandotorrent) or a bare info_hash (YTS API). `build/2` synthesizes
  a usable URI from the bare hash by appending a curated tracker list,
  and `info_hash/1` extracts the `xt=urn:btih:` parameter from any
  shape we encounter.

  We keep the tracker list small and aimed at high-availability public
  trackers — rqbit's DHT picks up the slack for everything else, and
  longer URIs make logs harder to scan.
  """

  # 8 well-known public UDP/HTTPS trackers. Curated from the magnets we
  # observed on gratistorrent — these are the ones the major Brazilian
  # release groups put on every torrent, so peers tend to be there
  # whether or not the YTS-supplied tracker list overlaps.
  @default_trackers [
    "udp://tracker.opentrackr.org:1337/announce",
    "udp://tracker.openbittorrent.com:80/announce",
    "udp://open.stealth.si:80/announce",
    "udp://tracker.coppersurfer.tk:6969/announce",
    "udp://exodus.desync.com:6969/announce",
    "udp://tracker.internetwarriors.net:1337/announce",
    "udp://explodie.org:6969/announce",
    "https://tracker.yemekyedim.com:443/announce"
  ]

  @doc """
  Builds a magnet URI from an info_hash + display name.

  ## Options

    * `:trackers` — extra trackers to include in addition to the
      defaults; deduped.
  """
  @spec build(String.t(), String.t(), keyword()) :: String.t()
  def build(info_hash, display_name \\ "", opts \\ [])
      when is_binary(info_hash) and is_binary(display_name) do
    extra_trackers = Keyword.get(opts, :trackers, [])
    trackers = Enum.uniq(@default_trackers ++ extra_trackers)

    parts = ["xt=urn:btih:#{normalize_hash(info_hash)}"]

    parts =
      if display_name != "", do: parts ++ ["dn=#{URI.encode_www_form(display_name)}"], else: parts

    parts = parts ++ Enum.map(trackers, fn t -> "tr=#{URI.encode_www_form(t)}" end)

    "magnet:?" <> Enum.join(parts, "&")
  end

  @doc """
  Pulls the lowercased 40-hex info_hash out of any magnet URI.

  Both encodings BEP 9 allows are accepted: 40 hex characters and 32
  base32 characters (gratistorrent.com publishes the latter); base32 is
  converted to hex. Returns `nil` when the URI doesn't carry a usable
  `xt=urn:btih:` slot.
  """
  @spec info_hash(String.t()) :: String.t() | nil
  def info_hash(magnet) when is_binary(magnet) do
    case btih(magnet) do
      {_raw, hex} -> hex
      nil -> nil
    end
  end

  @doc """
  Returns the magnet with a base32 `btih` rewritten to its hex form, so
  every downstream consumer (dedupe, rqbit) sees one canonical encoding.
  Hex magnets are returned untouched.
  """
  @spec normalize(String.t()) :: String.t()
  def normalize(magnet) when is_binary(magnet) do
    case btih(magnet) do
      {raw, hex} when byte_size(raw) == 32 ->
        String.replace(magnet, "urn:btih:" <> raw, "urn:btih:" <> hex, global: false)

      _ ->
        magnet
    end
  end

  defp btih(magnet) do
    case Regex.run(~r/xt=urn:btih:([0-9a-fA-F]{40}|[A-Za-z2-7]{32})(?![0-9A-Za-z])/, magnet,
           capture: :all_but_first
         ) do
      [raw] when byte_size(raw) == 40 -> {raw, String.downcase(raw)}
      [raw] -> base32_to_hex(raw)
      _ -> nil
    end
  end

  defp base32_to_hex(raw) do
    case Base.decode32(String.upcase(raw)) do
      {:ok, <<_::binary-size(20)>> = digest} -> {raw, Base.encode16(digest, case: :lower)}
      _ -> nil
    end
  end

  @doc """
  Pulls the display name (`dn=`) out of a magnet URI, URL-decoded.
  """
  @spec display_name(String.t()) :: String.t() | nil
  def display_name(magnet) when is_binary(magnet) do
    case Regex.run(~r/[?&]dn=([^&]+)/, magnet, capture: :all_but_first) do
      [encoded] -> URI.decode_www_form(encoded)
      _ -> nil
    end
  end

  @doc """
  Extracts every `tr=` tracker URL from the magnet.
  """
  @spec trackers(String.t()) :: [String.t()]
  def trackers(magnet) when is_binary(magnet) do
    Regex.scan(~r/[?&]tr=([^&]+)/, magnet, capture: :all_but_first)
    |> Enum.map(fn [tracker] -> URI.decode_www_form(tracker) end)
  end

  @doc """
  The default tracker list as a plain Elixir list — exposed mostly so
  tests can assert on it without copying the constant.
  """
  def default_trackers, do: @default_trackers

  defp normalize_hash(hash) when is_binary(hash), do: String.downcase(hash)
end
