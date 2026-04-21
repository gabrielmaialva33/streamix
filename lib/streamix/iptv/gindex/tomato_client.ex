defmodule Streamix.Iptv.Gindex.TomatoClient do
  @moduledoc """
  Thin read-only client for the TomatoAnimes edge API
  (`https://edge.betomato.com/v2`).

  Used as the primary enrichment source for anime rows — the catalog is
  already in romaji with Portuguese plot/tags attached, which maps
  directly onto the way brazilian gindex folders are named. AniList and
  TMDB stay in the rotation as fallbacks for titles Tomato doesn't have.

  Auth is a bearer token in the `TOMATO_BEARER_TOKEN` env var. The
  endpoints we consume don't use user scope, so a single long-lived
  token is enough for catalog enrichment. Paced through
  `Streamix.Iptv.Gindex.Pacer` (`:tomato`, default 2 rps).
  """

  alias Streamix.Iptv.Gindex.Pacer

  require Logger

  @timeout :timer.seconds(10)

  @spec enabled?() :: boolean()
  def enabled? do
    cfg = config()
    cfg[:enabled] == true and is_binary(cfg[:bearer_token]) and cfg[:bearer_token] != ""
  end

  @type search_result :: %{
          tomato_id: integer(),
          name: String.t(),
          image: String.t() | nil,
          year: integer() | nil,
          episodes: integer(),
          tags: [String.t()],
          dubbed: boolean(),
          type: String.t(),
          priority: integer()
        }

  @doc """
  Searches the Tomato catalog. `content_type` accepts `"all"`,
  `"anime"`, `"manga"` — we default to `"anime"` because the enrichment
  caller only cares about animation series.
  """
  @spec search_anime(String.t(), keyword()) ::
          {:ok, [search_result()]} | {:error, term()}
  def search_anime(query, opts \\ []) when is_binary(query) do
    if enabled?() do
      Pacer.acquire(:tomato)

      body = %{
        "token" => bearer_token(),
        "search" => query,
        "content_type" => Keyword.get(opts, :content_type, "anime"),
        "page" => Keyword.get(opts, :page, 0)
      }

      post("/v2/content/search", body)
      |> handle_search()
    else
      {:error, :tomato_not_configured}
    end
  end

  @doc "Fetches full details for a known anime id."
  @spec anime_details(integer()) :: {:ok, map()} | {:error, term()}
  def anime_details(tomato_id) when is_integer(tomato_id) do
    if enabled?() do
      Pacer.acquire(:tomato)

      get("/v2/anime/#{tomato_id}")
      |> handle_details()
    else
      {:error, :tomato_not_configured}
    end
  end

  # --- HTTP ---

  defp post(path, body) do
    url(path)
    |> Req.post(
      json: body,
      headers: headers(),
      receive_timeout: @timeout,
      finch: Streamix.Finch
    )
  end

  defp get(path) do
    url(path)
    |> Req.get(
      headers: headers(),
      receive_timeout: @timeout,
      finch: Streamix.Finch
    )
  end

  defp handle_search({:ok, %{status: 200, body: %{"status" => true, "result" => list}}})
       when is_list(list) do
    {:ok, Enum.map(list, &normalize_search/1)}
  end

  defp handle_search({:ok, %{status: 200, body: %{"status" => false} = body}}) do
    Logger.warning("[Tomato] search returned status=false body=#{inspect(body)}")
    {:error, :not_ok}
  end

  defp handle_search({:ok, %{status: 401}}), do: {:error, :unauthorized}
  defp handle_search({:ok, %{status: 429}}), do: {:error, :rate_limited}
  defp handle_search({:ok, %{status: status}}), do: {:error, {:http_error, status}}
  defp handle_search({:error, reason}), do: {:error, reason}

  defp handle_details({:ok, %{status: 200, body: %{"anime_details" => details} = body}})
       when is_map(details) do
    {:ok, Map.put(details, "_envelope", Map.delete(body, "anime_details"))}
  end

  defp handle_details({:ok, %{status: 401}}), do: {:error, :unauthorized}
  defp handle_details({:ok, %{status: 404}}), do: {:error, :not_found}
  defp handle_details({:ok, %{status: 429}}), do: {:error, :rate_limited}
  defp handle_details({:ok, %{status: status}}), do: {:error, {:http_error, status}}
  defp handle_details({:error, reason}), do: {:error, reason}

  # --- normalization ---

  defp normalize_search(item) do
    tags = parse_tags(item["tags"])

    %{
      tomato_id: item["id"],
      name: item["name"] || "",
      image: item["image"],
      year: parse_year(item["date"]),
      episodes: item["episodes"] || 0,
      tags: tags,
      dubbed: "DUBLADO" in tags,
      type: item["type"] || "anime",
      priority: item["priority"] || 0
    }
  end

  defp parse_tags(nil), do: []
  defp parse_tags(""), do: []

  defp parse_tags(str) when is_binary(str) do
    str
    |> String.split(~r/,\s*/)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&String.upcase/1)
  end

  defp parse_year(nil), do: nil
  defp parse_year(""), do: nil

  defp parse_year(str) when is_binary(str) do
    case Integer.parse(str) do
      {year, _} -> year
      :error -> nil
    end
  end

  defp parse_year(int) when is_integer(int), do: int
  defp parse_year(_), do: nil

  # --- config ---

  defp url(path), do: base_url() <> path

  defp headers do
    [
      {"Authorization", "Bearer #{bearer_token()}"},
      {"Accept", "application/json"},
      {"User-Agent", "streamix/1.0 (+https://github.com/gabrielmaialva33/streamix)"}
    ]
  end

  defp bearer_token, do: config()[:bearer_token]
  defp base_url, do: config()[:base_url] || "https://edge.betomato.com"
  defp config, do: Application.get_env(:streamix, :tomato, [])
end
