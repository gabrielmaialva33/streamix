defmodule Streamix.Gindex.TomatoClient do
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
  `Streamix.Gindex.Pacer` (`:tomato`, default 2 rps).
  """

  alias Streamix.Gindex.Pacer

  require Logger

  @timeout :timer.seconds(10)
  # Tomato answers a banned account with `status_code` 12 on every call. The
  # ban outlives any retry, so the client stands down for a day instead of
  # spending a paced request (and a log line) on each anime it enriches;
  # AniList and TMDB carry on as the fallbacks they already are.
  @banned_status_code 12
  @ban_pause_ms :timer.hours(24)
  @suspension_key {__MODULE__, :suspended_until}

  @spec enabled?() :: boolean()
  def enabled? do
    cfg = config()

    cfg[:enabled] == true and is_binary(cfg[:bearer_token]) and cfg[:bearer_token] != "" and
      not suspended?()
  end

  @doc "True while a ban answer keeps the client paused."
  @spec suspended?() :: boolean()
  def suspended? do
    case :persistent_term.get(@suspension_key, nil) do
      nil -> false
      until -> System.monotonic_time(:millisecond) < until
    end
  end

  @doc false
  @spec reset_suspension() :: :ok
  def reset_suspension do
    :persistent_term.erase(@suspension_key)
    :ok
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
    Req.post(
      url(path),
      req(
        json: body,
        headers: headers(),
        receive_timeout: @timeout,
        finch: [name: Streamix.Finch]
      )
    )
  end

  # Tests route the client to a stub through `config :streamix, :tomato,
  # req_options: [plug: ...]`.
  defp req(opts), do: Keyword.merge(opts, config()[:req_options] || [])

  defp get(path) do
    Req.get(
      url(path),
      req(headers: headers(), receive_timeout: @timeout, finch: [name: Streamix.Finch])
    )
  end

  defp handle_search({:ok, %{status: 200, body: %{"status" => true, "result" => list}}})
       when is_list(list) do
    {:ok, Enum.map(list, &normalize_search/1)}
  end

  defp handle_search(
         {:ok, %{status: 200, body: %{"status" => false, "status_code" => @banned_status_code}}}
       ) do
    suspend()
    {:error, :banned}
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

  defp suspend do
    unless suspended?() do
      :persistent_term.put(@suspension_key, System.monotonic_time(:millisecond) + @ban_pause_ms)

      Logger.warning(
        "[Tomato] the API reports this account as banned; pausing Tomato enrichment for 24h"
      )
    end

    :ok
  end

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
