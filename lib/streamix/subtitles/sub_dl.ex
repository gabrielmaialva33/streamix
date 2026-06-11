defmodule Streamix.Subtitles.SubDL do
  @moduledoc """
  SubDL provider (subdl.com REST API).

  Search by `imdb_id` + `languages` returns matches whose `url` points at
  a ZIP on `dl.subdl.com`; the ZIP holds one or more `.srt` files. We
  download it, extract the first subtitle, and hand the bytes back. Needs
  a free API key (`SUBDL_API_KEY`); absent key reports `enabled?: false`.

  SubDL's free tier is more permissive than OpenSubtitles, so it makes a
  good second link in the `Streamix.Subtitles` chain.
  """

  @behaviour Streamix.Subtitles.Source

  require Logger

  @api "https://api.subdl.com/api/v1/subtitles"
  @dl_base "https://dl.subdl.com"
  @slug "subdl"
  @timeout :timer.seconds(10)

  @impl true
  def slug, do: @slug

  @impl true
  def enabled?, do: is_binary(api_key()) and api_key() != ""

  @impl true
  def fetch(imdb_id, lang) do
    with {:ok, zip_path} <- search_best(imdb_id, lang),
         {:ok, zip} <- download(@dl_base <> zip_path) do
      extract_first_srt(zip)
    end
  end

  defp search_best(imdb_id, lang) do
    query =
      URI.encode_query(%{
        "api_key" => api_key(),
        "imdb_id" => imdb_id,
        "languages" => normalize_lang(lang),
        "subs_per_page" => "10"
      })

    case Req.get(@api <> "?" <> query, receive_timeout: @timeout) do
      {:ok, %{status: 200, body: %{"subtitles" => subs}}} when is_list(subs) and subs != [] ->
        case Enum.find_value(subs, &subtitle_url/1) do
          nil -> {:error, :no_file}
          url -> {:ok, url}
        end

      {:ok, %{status: 200}} ->
        {:error, :not_found}

      {:ok, %{status: status}} ->
        {:error, {:search_failed, status}}

      {:error, reason} ->
        {:error, reason}
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

  # The ZIP can hold multiple files; take the first `.srt`.
  defp extract_first_srt(zip) do
    case :zip.extract(zip, [:memory]) do
      {:ok, files} ->
        files
        |> Enum.find(fn {name, _} -> String.ends_with?(to_string(name), ".srt") end)
        |> case do
          {_name, bytes} -> {:ok, bytes}
          nil -> {:error, :no_srt_in_zip}
        end

      {:error, reason} ->
        {:error, {:bad_zip, reason}}
    end
  end

  defp subtitle_url(%{"url" => url}) when is_binary(url) and url != "", do: url
  defp subtitle_url(_), do: nil

  # SubDL uses two-letter uppercase codes ("PT", "EN") for the primary
  # language; BR Portuguese is "PT-BR".
  defp normalize_lang(lang) do
    case lang |> to_string() |> String.downcase() do
      "pt-br" -> "PT-BR"
      "pt" <> _ -> "PT"
      other -> other |> String.split("-") |> hd() |> String.upcase()
    end
  end

  defp api_key, do: config()[:api_key]
  defp config, do: Application.get_env(:streamix, :subdl, [])
end
