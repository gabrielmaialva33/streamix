defmodule Streamix.Gindex.AnilistClient do
  @moduledoc """
  Thin GraphQL client for AniList's public search endpoint.

  Used as a fallback enrichment source for anime rows that TMDB can't
  match (romaji titles with fansub prefixes, anime movies that only
  exist in AniList's catalog, etc.). Read queries need no auth — the
  OAuth client we registered on AniList is only relevant once we start
  touching user-scoped data, which this module does not.

  Rate-limited through `Streamix.Gindex.Pacer` (`:anilist` bucket,
  default 1 req/sec) to stay comfortably under AniList's 90/min ceiling.
  """

  alias Streamix.Gindex.Pacer

  require Logger

  @endpoint "https://graphql.anilist.co"
  @timeout :timer.seconds(10)

  @search_query """
  query ($search: String!, $seasonYear: Int) {
    Page(perPage: 5) {
      media(type: ANIME, search: $search, seasonYear: $seasonYear, sort: SEARCH_MATCH) {
        id
        seasonYear
        popularity
        format
        title {
          romaji
          english
          native
        }
        synonyms
        coverImage {
          extraLarge
          large
        }
      }
    }
  }
  """

  @type candidate :: %{
          anilist_id: integer(),
          title_romaji: String.t() | nil,
          title_english: String.t() | nil,
          title_native: String.t() | nil,
          synonyms: [String.t()],
          cover_url: String.t() | nil,
          season_year: integer() | nil,
          popularity: number(),
          format: String.t() | nil
        }

  @spec search_anime(String.t(), integer() | nil) ::
          {:ok, [candidate()]} | {:error, term()}
  def search_anime(query, season_year \\ nil) when is_binary(query) do
    Pacer.acquire(:anilist)

    body = %{
      "query" => @search_query,
      "variables" => %{"search" => query, "seasonYear" => season_year}
    }

    @endpoint
    |> Req.post(
      json: body,
      receive_timeout: @timeout,
      finch: Streamix.Finch,
      headers: [{"accept", "application/json"}]
    )
    |> handle_response()
  end

  # --- response handling ---

  defp handle_response({:ok, %{status: 200, body: %{"data" => %{"Page" => %{"media" => list}}}}})
       when is_list(list) do
    {:ok, Enum.map(list, &normalize/1)}
  end

  defp handle_response({:ok, %{status: 200, body: %{"errors" => errors}}}) do
    {:error, {:graphql_error, errors}}
  end

  defp handle_response({:ok, %{status: 429}}), do: {:error, :rate_limited}

  defp handle_response({:ok, %{status: status, body: body}}) do
    Logger.warning("[AniList] unexpected status=#{status} body=#{inspect(body)}")
    {:error, {:http_error, status}}
  end

  defp handle_response({:error, reason}), do: {:error, reason}

  defp normalize(%{} = item) do
    title = item["title"] || %{}
    cover = item["coverImage"] || %{}

    %{
      anilist_id: item["id"],
      title_romaji: title["romaji"],
      title_english: title["english"],
      title_native: title["native"],
      synonyms: item["synonyms"] || [],
      cover_url: cover["extraLarge"] || cover["large"],
      season_year: item["seasonYear"],
      popularity: item["popularity"] || 0,
      format: item["format"]
    }
  end
end
