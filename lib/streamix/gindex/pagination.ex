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
    list_from_endpoints(Enum.uniq(base_urls), path, request_fun, [])
  end

  def list_folder_all([], _path, _opts), do: {:error, :no_gindex_endpoints}

  defp list_from_endpoints([], path, _request_fun, failures) do
    partial_error(path, failures)
  end

  defp list_from_endpoints([base_url | remaining], path, request_fun, failures) do
    case list_folder_paginated(base_url, path, nil, 0, [], request_fun) do
      {:ok, items} ->
        {:ok, items}

      {:error, {:quota_exhausted, _count} = reason} ->
        {:error, reason}

      {:error, failure} ->
        retry_from_next_endpoint(remaining, path, request_fun, [failure | failures])
    end
  end

  defp retry_from_next_endpoint([], path, request_fun, failures) do
    list_from_endpoints([], path, request_fun, failures)
  end

  defp retry_from_next_endpoint([next | _] = remaining, path, request_fun, failures) do
    Logger.info("[GIndex Pagination] restarting #{path} from page 0 on fallback endpoint #{next}")

    list_from_endpoints(remaining, path, request_fun, failures)
  end

  # GIndex 2.3.6 expects the cursor and its matching page index together.
  # Its own app.min.js sends `nextPageToken` with `curPageIndex + 1`.
  # Keeping page_index at zero repeats the first page until worker.js
  # eventually crashes with a TypeError.
  defp list_folder_paginated(base_url, path, page_token, log_page, acc, request_fun) do
    body =
      Jason.encode!(%{
        id: "",
        type: "folder",
        password: "",
        page_token: page_token,
        page_index: log_page
      })

    case request_page(base_url, path, body, request_fun) do
      {:ok, response_body} ->
        handle_page_response(
          response_body,
          base_url,
          path,
          log_page,
          acc,
          request_fun
        )

      {:error, {:quota_exhausted, _count} = reason} ->
        {:error, reason}

      {:error, reason} ->
        endpoint_failure(base_url, log_page, acc, reason)
    end
  end

  defp handle_page_response(
         response_body,
         base_url,
         path,
         log_page,
         acc,
         request_fun
       ) do
    case Response.parse_folder_with_token(response_body, base_url, path) do
      {:ok, items, nil} ->
        {:ok, acc ++ items}

      {:ok, items, next_token} ->
        Logger.debug("[GIndex] Fetching page #{log_page + 1}...")
        Process.sleep(page_delay())

        list_folder_paginated(
          base_url,
          path,
          next_token,
          log_page + 1,
          acc ++ items,
          request_fun
        )

      {:error, reason} ->
        endpoint_failure(base_url, log_page, acc, reason)
    end
  end

  defp request_page(base_url, path, body, request_fun) do
    url = Url.join(base_url, path)

    case request_fun.(:post, url, body, base_url) do
      {:ok, %{status: 200, body: response_body}} ->
        {:ok, response_body}

      {:ok, %{status: status}} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp endpoint_failure(base_url, page, acc, reason) do
    {:error,
     %{
       endpoint: base_url,
       page: page,
       items_collected: length(acc),
       reason: reason
     }}
  end

  defp partial_error(path, failures) do
    failures = Enum.reverse(failures)
    best = Enum.max_by(failures, & &1.items_collected)

    Logger.warning(
      "[GIndex Pagination] incomplete result for #{path}: " <>
        "best attempt stopped after page #{best.page} with #{best.items_collected} items, " <>
        "reason=#{inspect({:all_endpoints_failed, failures})}"
    )

    {:error,
     {:partial_listing,
      %{
        path: path,
        page: best.page,
        items_collected: best.items_collected,
        reason: {:all_endpoints_failed, failures}
      }}}
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
