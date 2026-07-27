defmodule Streamix.Gindex.Pagination do
  @moduledoc """
  Paginated folder listing for GIndex workers.
  """

  require Logger

  alias Streamix.Gindex.Response
  alias Streamix.Gindex.Transport
  alias Streamix.Gindex.Url

  def list_folder_all(base_urls, path, opts \\ [])

  def list_folder_all(base_url, path, opts) when is_binary(base_url) do
    list_folder_all([base_url], path, opts)
  end

  def list_folder_all([_ | _] = base_urls, path, opts) do
    request_fun = Keyword.get(opts, :request_fun, &Transport.request/4)
    list_folder_paginated(Enum.uniq(base_urls), path, nil, 0, [], request_fun)
  end

  def list_folder_all([], _path, _opts), do: {:error, :no_gindex_endpoints}

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
  defp list_folder_paginated(base_urls, path, page_token, log_page, acc, request_fun) do
    body =
      Jason.encode!(%{
        id: "",
        type: "folder",
        password: "",
        page_token: page_token,
        page_index: 0
      })

    case request_page(base_urls, path, body, request_fun) do
      {:ok, response_body, active_base_url, ordered_base_urls} ->
        handle_page_response(
          response_body,
          active_base_url,
          ordered_base_urls,
          path,
          log_page,
          acc,
          request_fun
        )

      {:error, {:quota_exhausted, _count} = reason} ->
        {:error, reason}

      {:error, reason} ->
        partial_error(acc, path, log_page, reason)
    end
  end

  defp handle_page_response(
         response_body,
         active_base_url,
         base_urls,
         path,
         log_page,
         acc,
         request_fun
       ) do
    case Response.parse_folder_with_token(response_body, active_base_url, path) do
      {:ok, items, nil} ->
        {:ok, acc ++ items}

      {:ok, items, next_token} ->
        Logger.debug("[GIndex] Fetching page #{log_page + 1}...")
        Process.sleep(page_delay())

        list_folder_paginated(
          base_urls,
          path,
          next_token,
          log_page + 1,
          acc ++ items,
          request_fun
        )

      {:error, reason} ->
        partial_error(acc, path, log_page, reason)
    end
  end

  defp request_page(base_urls, path, body, request_fun) do
    base_urls
    |> Enum.reduce_while([], &request_endpoint(&1, &2, base_urls, path, body, request_fun))
    |> normalize_page_result()
  end

  defp request_endpoint(base_url, errors, base_urls, path, body, request_fun) do
    url = Url.join(base_url, path)
    result = request_fun.(:post, url, body, base_url)
    classify_endpoint_result(result, base_url, base_urls, errors)
  end

  defp classify_endpoint_result(
         {:ok, %{status: 200, body: response_body}},
         base_url,
         base_urls,
         _errors
       ) do
    if base_url != hd(base_urls) do
      Logger.info("[GIndex Pagination] switched to fallback endpoint #{base_url}")
    end

    ordered_base_urls = [base_url | Enum.reject(base_urls, &(&1 == base_url))]
    {:halt, {:ok, response_body, base_url, ordered_base_urls}}
  end

  defp classify_endpoint_result(
         {:ok, %{status: status}},
         base_url,
         _base_urls,
         errors
       ) do
    {:cont, [{base_url, {:http_error, status}} | errors]}
  end

  defp classify_endpoint_result(
         {:error, {:quota_exhausted, _count} = reason},
         _base_url,
         _base_urls,
         _errors
       ) do
    {:halt, {:error, reason}}
  end

  defp classify_endpoint_result({:error, reason}, base_url, _base_urls, errors) do
    {:cont, [{base_url, reason} | errors]}
  end

  defp normalize_page_result([]), do: {:error, :no_gindex_endpoints}
  defp normalize_page_result({:ok, _, _, _} = success), do: success
  defp normalize_page_result({:error, _} = error), do: error

  defp normalize_page_result(errors) do
    {:error, {:all_endpoints_failed, Enum.reverse(errors)}}
  end

  defp partial_error(acc, path, log_page, reason) do
    Logger.warning(
      "[GIndex Pagination] incomplete result for #{path}: " <>
        "stopped after page #{log_page} with #{length(acc)} items, reason=#{inspect(reason)}"
    )

    {:error,
     {:partial_listing,
      %{path: path, page: log_page, items_collected: length(acc), reason: reason}}}
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
