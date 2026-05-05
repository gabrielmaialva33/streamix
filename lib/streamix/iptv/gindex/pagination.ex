defmodule Streamix.Iptv.Gindex.Pagination do
  @moduledoc """
  Paginated folder listing for GIndex workers.
  """

  require Logger

  alias Streamix.Iptv.Gindex.Response
  alias Streamix.Iptv.Gindex.Transport
  alias Streamix.Iptv.Gindex.Url

  def list_folder_all(base_url, path) do
    list_folder_paginated(base_url, path, nil, 0, [])
  end

  defp list_folder_paginated(base_url, path, page_token, page_index, acc) do
    body =
      Jason.encode!(%{
        id: "",
        type: "folder",
        password: "",
        page_token: page_token,
        page_index: page_index
      })

    url = Url.join(base_url, path)

    case Transport.request(:post, url, body, base_url) do
      {:ok, %{status: 200, body: response_body}} ->
        handle_page_response(response_body, base_url, path, page_index, acc)

      {:ok, %{status: status}} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp handle_page_response(response_body, base_url, path, page_index, acc) do
    case Response.parse_folder_with_token(response_body, base_url, path) do
      {:ok, items, nil} ->
        {:ok, acc ++ items}

      {:ok, items, next_token} ->
        Logger.debug("[GIndex] Fetching page #{page_index + 1}...")
        Process.sleep(60_000 + :rand.uniform(5_000))
        list_folder_paginated(base_url, path, next_token, page_index + 1, acc ++ items)

      {:error, reason} ->
        {:error, reason}
    end
  end
end
