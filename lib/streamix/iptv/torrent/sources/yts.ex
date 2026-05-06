defmodule Streamix.Iptv.Torrent.Sources.Yts do
  @moduledoc """
  YTS source — implements `Streamix.Iptv.Torrent.Source` against the
  yts.bz/api/v2 JSON API.

  YTS exposes ~75k movies, every one with a hash + size + seeders
  rolled into a single response page (50 items max). We translate
  each `torrent` row into a `Source.magnet_info` and the parent movie
  into a `Source.listing_item`, leaving the rest of the catalog
  pipeline (`movies` + `torrent_streams` upserts, TMDB enrichment) to
  the orchestrator.

  The API gives us a bare info_hash, not a full magnet URI, so we
  synthesize one with `Magnet.build/3` and the curated tracker list.
  """

  @behaviour Streamix.Iptv.Torrent.Source

  alias Streamix.Iptv.Torrent.Magnet

  @slug "yts"
  @name "YTS"
  @endpoint "https://yts.bz/api/v2/list_movies.json"
  @rate_limit_ms 200
  @page_size 50

  @impl true
  def slug, do: @slug

  @impl true
  def name, do: @name

  @impl true
  def rate_limit_ms, do: @rate_limit_ms

  @impl true
  def fetch_listing(opts \\ []) do
    page = Keyword.get(opts, :page, 1)
    limit = Keyword.get(opts, :limit, @page_size)

    params = [
      limit: limit,
      page: page,
      sort_by: "date_added",
      order_by: "desc"
    ]

    case Req.get(@endpoint,
           params: params,
           receive_timeout: :timer.seconds(15),
           finch: Streamix.Finch,
           headers: [
             {"user-agent",
              "Mozilla/5.0 (compatible; Streamix/1.0; +https://streamix.mahina.cloud)"},
             {"accept", "application/json"}
           ],
           decode_json: [keys: :strings]
         ) do
      {:ok, %{status: 200, body: %{"status" => "ok", "data" => data}}} ->
        movies = Map.get(data, "movies", []) |> Enum.map(&decode_movie/1)
        meta = build_meta(data)
        {:ok, movies, meta}

      {:ok, %{status: 200, body: body}} ->
        {:error, {:bad_payload, body}}

      {:ok, %{status: status, body: body}} ->
        {:error, {:http_error, status, body}}

      {:error, %Req.TransportError{reason: reason}} ->
        {:error, {:transport_error, reason}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Internals

  defp build_meta(%{"movie_count" => total, "page_number" => page, "limit" => limit}) do
    %{
      total: total,
      page: page,
      limit: limit,
      next_page: maybe_next_page(total, page, limit)
    }
  end

  defp build_meta(_), do: %{total: nil, page: nil, limit: nil, next_page: nil}

  defp maybe_next_page(total, page, limit)
       when is_integer(total) and is_integer(page) and is_integer(limit) do
    if page * limit < total, do: page + 1, else: nil
  end

  defp maybe_next_page(_, _, _), do: nil

  @doc false
  # Public for tests; the orchestrator should never need to call this
  # directly — it goes through fetch_listing/1.
  def decode_movie(movie) when is_map(movie) do
    title = movie["title_english"] || movie["title"] || ""

    %{
      external_id: to_string(movie["id"]),
      title: title,
      year: movie["year"],
      imdb_id: movie["imdb_code"],
      tmdb_id: nil,
      poster_url:
        pick_first(movie, ["large_cover_image", "medium_cover_image", "small_cover_image"]),
      backdrop_url: pick_first(movie, ["background_image_original", "background_image"]),
      plot: pick_first(movie, ["description_full", "summary", "synopsis"]),
      rating: parse_rating(movie["rating"]),
      runtime_minutes: parse_runtime(movie["runtime"]),
      genres: movie["genres"] || [],
      torrents: Enum.map(movie["torrents"] || [], &decode_torrent(&1, title, movie["year"]))
    }
  end

  defp decode_torrent(torrent, title, year) when is_map(torrent) do
    info_hash = String.downcase(torrent["hash"] || "")
    display_name = display_name_for(title, year, torrent)

    %{
      info_hash: info_hash,
      magnet_uri: Magnet.build(info_hash, display_name),
      source_slug: @slug,
      quality: normalize_quality(torrent["quality"]),
      codec: torrent["video_codec"],
      audio_track: torrent["audio_channels"],
      container: nil,
      size_bytes: torrent["size_bytes"],
      seeders: torrent["seeds"] || 0,
      leechers: torrent["peers"] || 0
    }
  end

  defp display_name_for(title, year, torrent) do
    quality = torrent["quality"] || ""
    codec = torrent["video_codec"] || ""

    [title, year, quality, codec]
    |> Enum.reject(&(is_nil(&1) or &1 == ""))
    |> Enum.join(".")
  end

  # YTS uses "720p"/"1080p"/"2160p"/"3D" — drop "3D" since we don't
  # surface it as its own quality tier (it's an orientation hint).
  defp normalize_quality("3D"), do: nil
  defp normalize_quality(q) when q in ~w(480p 720p 1080p 2160p), do: q
  defp normalize_quality(_), do: nil

  defp parse_rating(rating) when is_number(rating), do: rating * 1.0
  defp parse_rating(_), do: nil

  defp parse_runtime(runtime) when is_integer(runtime) and runtime > 0, do: runtime
  defp parse_runtime(_), do: nil

  defp pick_first(map, keys) do
    Enum.find_value(keys, fn key ->
      case Map.get(map, key) do
        v when is_binary(v) and v != "" -> v
        _ -> nil
      end
    end)
  end
end
