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

  # GIndex worker pagination contract (verified against the upstream
  # Cloudflare Worker via curl probes):
  #
  #   * page_token=nil   + page_index=N  → returns page N
  #   * page_token=TOKEN + page_index=0  → returns the page after TOKEN
  #   * page_token=TOKEN + page_index>0  → HTTP 500 TypeError on the worker
  #
  # We pick the token-based variant: keep `page_index: 0` on the wire
  # and let the cursor advance via `nextPageToken`. `log_page` is
  # bookkeeping for log lines only and never reaches the request body.
  defp list_folder_paginated(base_url, path, page_token, log_page, acc) do
    body =
      Jason.encode!(%{
        id: "",
        type: "folder",
        password: "",
        page_token: page_token,
        page_index: 0
      })

    url = Url.join(base_url, path)

    case Transport.request(:post, url, body, base_url) do
      {:ok, %{status: 200, body: response_body}} ->
        handle_page_response(response_body, base_url, path, log_page, acc)

      {:ok, %{status: status}} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp handle_page_response(response_body, base_url, path, log_page, acc) do
    case Response.parse_folder_with_token(response_body, base_url, path) do
      {:ok, items, nil} ->
        {:ok, acc ++ items}

      {:ok, items, next_token} ->
        Logger.debug("[GIndex] Fetching page #{log_page + 1}...")
        Process.sleep(page_delay())
        list_folder_paginated(base_url, path, next_token, log_page + 1, acc ++ items)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp page_delay do
    config = Application.get_env(:streamix, __MODULE__, [])
    delay_ms = Keyword.get(config, :delay_ms, 5_000)
    jitter_ms = Keyword.get(config, :jitter_ms, 1_000)

    delay_ms + random_jitter(jitter_ms)
  end

  defp random_jitter(jitter_ms) when is_integer(jitter_ms) and jitter_ms > 0 do
    :rand.uniform(jitter_ms)
  end

  defp random_jitter(_), do: 0
end
