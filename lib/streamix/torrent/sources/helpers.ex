defmodule Streamix.Torrent.Sources.Helpers do
  @moduledoc """
  Shared source helpers for torrent indexers.

  Source modules should keep site-specific discovery thin and return
  normalized listing maps. This module owns the common parsing rules
  for configured JSON feeds, magnet metadata, quality, size and
  pagination so BR sources do not copy/paste fragile scraper code.
  """

  alias Streamix.Torrent.Magnet

  @headers [
    {"user-agent", "Mozilla/5.0 (compatible; Streamix/1.0; +https://streamix.mahina.fun)"},
    {"accept", "application/json"}
  ]

  @doc """
  Fetches a normalized JSON feed for a source slug.

  Expected payload:

      %{
        "items" => [
          %{
            "external_id" => "...",
            "title" => "...",
            "year" => 2026,
            "torrents" => [%{"magnet_uri" => "magnet:?...", "quality" => "1080p"}]
          }
        ],
        "meta" => %{"next_page" => 2}
      }

  A bare list is also accepted and treated as a single page.
  """
  @spec fetch_normalized_feed(String.t(), keyword()) ::
          {:ok, [map()], map()} | {:error, term()}
  def fetch_normalized_feed(slug, opts) when is_binary(slug) do
    with {:ok, endpoint} <- configured_endpoint(slug),
         {:ok, body} <- request_json(endpoint, opts),
         {:ok, items, meta} <- decode_feed(body, slug) do
      {:ok, items, normalize_meta(meta)}
    end
  end

  @spec configured_endpoint(String.t()) :: {:ok, String.t()} | {:error, :not_configured}
  def configured_endpoint(slug) do
    endpoints = Application.get_env(:streamix, :torrent_source_endpoints, %{})

    case endpoint_from_config(endpoints, slug) do
      endpoint when is_binary(endpoint) and endpoint != "" -> {:ok, endpoint}
      _ -> {:error, :not_configured}
    end
  end

  @spec normalize_quality(term()) :: String.t() | nil
  def normalize_quality(value) when is_binary(value) do
    value = String.downcase(value)

    cond do
      String.contains?(value, "2160") or String.contains?(value, "4k") -> "2160p"
      String.contains?(value, "1080") -> "1080p"
      String.contains?(value, "720") -> "720p"
      String.contains?(value, "480") -> "480p"
      true -> nil
    end
  end

  def normalize_quality(_), do: nil

  @spec parse_int(term()) :: integer() | nil
  def parse_int(value) when is_integer(value), do: value

  def parse_int(value) when is_binary(value) do
    case Regex.run(~r/\d+/, value) do
      [digits] -> String.to_integer(digits)
      _ -> nil
    end
  end

  def parse_int(_), do: nil

  @spec parse_rating(term()) :: float() | nil
  def parse_rating(value) when is_number(value), do: value * 1.0

  def parse_rating(value) when is_binary(value) do
    case Float.parse(String.replace(value, ",", ".")) do
      {rating, _} when rating >= 0 -> rating
      _ -> nil
    end
  end

  def parse_rating(_), do: nil

  @spec parse_size_bytes(term()) :: non_neg_integer() | nil
  def parse_size_bytes(value) when is_integer(value) and value >= 0, do: value

  def parse_size_bytes(value) when is_binary(value) do
    with [raw_number, raw_unit] <-
           Regex.run(~r/([\d\.,]+)\s*(kb|mb|gb|tb)/i, value, capture: :all_but_first),
         {number, _} <- Float.parse(String.replace(raw_number, ",", ".")) do
      multiplier =
        case String.downcase(raw_unit) do
          "kb" -> 1_024
          "mb" -> 1_048_576
          "gb" -> 1_073_741_824
          "tb" -> 1_099_511_627_776
        end

      round(number * multiplier)
    else
      _ -> nil
    end
  end

  def parse_size_bytes(_), do: nil

  @spec pick_first(map(), [String.t() | atom()]) :: term()
  def pick_first(map, keys) when is_map(map) and is_list(keys) do
    Enum.find_value(keys, fn key ->
      case Map.get(map, key) || Map.get(map, to_string(key)) do
        v when is_binary(v) and v != "" -> v
        v when not is_nil(v) -> v
        _ -> nil
      end
    end)
  end

  defp request_json(endpoint, opts) do
    page = Keyword.get(opts, :page, 1)
    limit = Keyword.get(opts, :limit, 50)

    case Req.get(endpoint,
           params: [page: page, limit: limit],
           receive_timeout: :timer.seconds(20),
           finch: [name: Streamix.Finch],
           headers: @headers,
           decoders: [json: &Jason.decode(&1, keys: :strings)]
         ) do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      {:ok, %{status: status, body: body}} -> {:error, {:http_error, status, body}}
      {:error, %Req.TransportError{reason: reason}} -> {:error, {:transport_error, reason}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode_feed(%{"items" => items} = body, slug) when is_list(items) do
    {:ok, Enum.map(items, &decode_item(&1, slug)), Map.get(body, "meta", %{})}
  end

  defp decode_feed(items, slug) when is_list(items) do
    {:ok, Enum.map(items, &decode_item(&1, slug)), %{}}
  end

  defp decode_feed(body, _slug), do: {:error, {:bad_payload, body}}

  defp decode_item(item, slug) when is_map(item) do
    title = pick_first(item, ~w(title name)) || ""

    %{
      external_id: to_string(pick_first(item, ~w(external_id id slug url)) || title),
      title: title,
      year: parse_int(pick_first(item, ~w(year release_year))),
      imdb_id: pick_first(item, ~w(imdb_id imdb_code)),
      tmdb_id: parse_int(pick_first(item, ~w(tmdb_id))),
      poster_url: pick_first(item, ~w(poster_url poster cover image)),
      backdrop_url: pick_first(item, ~w(backdrop_url backdrop background)),
      plot: pick_first(item, ~w(plot summary synopsis description)),
      rating: parse_rating(pick_first(item, ~w(rating imdb_rating))),
      runtime_minutes: parse_int(pick_first(item, ~w(runtime_minutes runtime))),
      genres: List.wrap(pick_first(item, ~w(genres categories))),
      torrents:
        Enum.map(List.wrap(item["torrents"] || item[:torrents]), &decode_torrent(&1, slug, title))
    }
  end

  defp decode_torrent(torrent, slug, title) when is_map(torrent) do
    raw_magnet_uri = pick_first(torrent, ~w(magnet_uri magnet url))
    info_hash = torrent_info_hash(torrent, raw_magnet_uri)

    %{
      info_hash: normalize_info_hash(info_hash),
      magnet_uri: torrent_magnet_uri(raw_magnet_uri, info_hash, title),
      source_slug: torrent_source_slug(torrent, slug),
      quality: torrent_quality(torrent, title),
      codec: pick_first(torrent, ~w(codec video_codec)),
      audio_track: pick_first(torrent, ~w(audio_track audio audio_channels)),
      container: pick_first(torrent, ~w(container extension ext)),
      size_bytes: parse_size_bytes(pick_first(torrent, ~w(size_bytes size))),
      seeders: parse_int(pick_first(torrent, ~w(seeders seeds))) || 0,
      leechers: parse_int(pick_first(torrent, ~w(leechers peers))) || 0
    }
  end

  defp decode_torrent(magnet_uri, slug, title) when is_binary(magnet_uri) do
    %{
      info_hash: Magnet.info_hash(magnet_uri),
      magnet_uri: magnet_uri,
      source_slug: slug,
      quality: normalize_quality(title),
      seeders: 0,
      leechers: 0
    }
  end

  defp torrent_info_hash(torrent, magnet_uri) do
    pick_first(torrent, ~w(info_hash hash)) || Magnet.info_hash(magnet_uri || "")
  end

  defp normalize_info_hash(info_hash) when is_binary(info_hash), do: String.downcase(info_hash)
  defp normalize_info_hash(_), do: nil

  defp torrent_magnet_uri(magnet_uri, _info_hash, _title) when is_binary(magnet_uri),
    do: magnet_uri

  defp torrent_magnet_uri(_magnet_uri, info_hash, title) when is_binary(info_hash),
    do: Magnet.build(info_hash, title)

  defp torrent_magnet_uri(_, _, _), do: nil

  defp torrent_source_slug(torrent, fallback_slug) do
    pick_first(torrent, ~w(source_slug source)) || fallback_slug
  end

  defp torrent_quality(torrent, title) do
    (pick_first(torrent, ~w(quality resolution title name)) || title)
    |> normalize_quality()
  end

  defp normalize_meta(meta) when is_map(meta) do
    %{
      total: parse_int(pick_first(meta, ~w(total count))),
      page: parse_int(pick_first(meta, ~w(page page_number))),
      limit: parse_int(pick_first(meta, ~w(limit page_size))),
      next_page: parse_int(pick_first(meta, ~w(next_page next)))
    }
  end

  defp endpoint_key("eztv"), do: :eztv
  defp endpoint_key("gratistorrent"), do: :gratistorrent
  defp endpoint_key("comandotorrent"), do: :comandotorrent
  defp endpoint_key(_), do: nil

  defp endpoint_from_config(endpoints, slug) when is_map(endpoints) do
    Map.get(endpoints, slug) || Map.get(endpoints, endpoint_key(slug))
  end

  defp endpoint_from_config(endpoints, slug) when is_list(endpoints) do
    Keyword.get(endpoints, endpoint_key(slug))
  end

  defp endpoint_from_config(_endpoints, _slug), do: nil
end
