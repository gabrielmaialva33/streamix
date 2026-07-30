defmodule Streamix.Subtitles.OpenSubtitles do
  @moduledoc """
  OpenSubtitles REST API v1 provider (api.opensubtitles.com).

  Two-step protocol: search by `imdb_id` + `languages`, then exchange the
  best match's `file_id` for a short-lived download URL. Requires a free
  API key (`OPENSUBTITLES_API_KEY`); without it the provider reports
  `enabled?: false` and the facade degrades to "no subtitle".

  The free tier has a tight daily download quota, which is why
  `Streamix.Subtitles` caches aggressively — a given imdb_id+lang is
  fetched from here at most once until the cache expires.
  """

  @behaviour Streamix.Subtitles.Source

  @base "https://api.opensubtitles.com/api/v1"
  @slug "opensubtitles"
  @timeout :timer.seconds(10)

  @impl true
  def slug, do: @slug

  @impl true
  def enabled?, do: is_binary(api_key()) and api_key() != ""

  @impl true
  def fetch(imdb_id, lang) do
    with {:ok, file_id} <- search_best_file(imdb_id, lang),
         {:ok, url} <- request_download_url(file_id) do
      download(url)
    end
  end

  defp search_best_file(imdb_id, lang) do
    query = URI.encode_query(%{"imdb_id" => imdb_id, "languages" => normalize_lang(lang)})

    case req(:get, "/subtitles?" <> query) do
      {:ok, %{status: 200, body: %{"data" => data}}} when is_list(data) and data != [] ->
        file_id =
          data
          |> Enum.sort_by(&download_count/1, :desc)
          |> Enum.find_value(&first_file_id/1)

        if file_id, do: {:ok, file_id}, else: {:error, :no_file}

      {:ok, %{status: 200}} ->
        {:error, :not_found}

      {:ok, %{status: status}} ->
        {:error, {:search_failed, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp request_download_url(file_id) do
    case req(:post, "/download", %{"file_id" => file_id}) do
      {:ok, %{status: 200, body: %{"link" => link}}} when is_binary(link) -> {:ok, link}
      {:ok, %{status: status}} -> {:error, {:download_request_failed, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp download(url) do
    case Req.get(url, receive_timeout: @timeout, decode_body: false) do
      {:ok, %{status: 200, body: body}} when is_binary(body) and byte_size(body) > 0 ->
        {:ok, body}

      {:ok, %{status: status}} ->
        {:error, {:download_failed, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp first_file_id(%{"attributes" => %{"files" => [%{"file_id" => id} | _]}}), do: id
  defp first_file_id(_), do: nil

  defp download_count(%{"attributes" => %{"download_count" => n}}) when is_integer(n), do: n
  defp download_count(_), do: 0

  # OpenSubtitles expects lowercase, e.g. "pt-br" / "pt-pt" / "en".
  defp normalize_lang(lang), do: lang |> to_string() |> String.downcase()

  defp req(method, path, body \\ nil) do
    opts =
      [
        method: method,
        url: @base <> path,
        headers: [
          {"api-key", api_key()},
          {"user-agent", user_agent()},
          {"accept", "application/json"}
        ],
        receive_timeout: @timeout
      ]
      |> maybe_json_body(body)

    Req.request(opts)
  end

  defp maybe_json_body(opts, nil), do: opts
  defp maybe_json_body(opts, body), do: Keyword.put(opts, :json, body)

  defp api_key, do: config()[:api_key]
  defp user_agent, do: config()[:user_agent] || "Streamix v1"
  defp config, do: Application.get_env(:streamix, :open_subtitles, [])
end
