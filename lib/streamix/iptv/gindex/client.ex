defmodule Streamix.Iptv.Gindex.Client do
  @moduledoc """
  HTTP client for GIndex (Google Drive Index) servers.

  GIndex uses a JavaScript-based frontend that makes POST requests to fetch
  folder contents. This client mimics those requests.

  ## Multi-Endpoint Failover

  This client uses EndpointManager for automatic failover between multiple
  GIndex endpoints. If one endpoint starts failing, requests are automatically
  routed to healthy fallback endpoints.
  """

  require Logger

  alias Streamix.Iptv.Gindex.EndpointManager
  alias Streamix.Iptv.Gindex.HealthTracker
  alias Streamix.Iptv.Gindex.Pacer
  alias Streamix.Iptv.Gindex.SingleFlight

  @default_timeout :timer.seconds(30)
  @retry_delay :timer.seconds(2)
  @max_retries 3
  # The upstream Cloudflare Worker for this provider ships transient 500s
  # a few times a minute — the previous 30s × 5 backoff meant a single
  # flaky folder could burn 15 minutes of a ScanRoot's 30-minute budget.
  # 2s base × 3 tries (2s + 4s + 8s = ~14s max) is aggressive enough to
  # recover on the same burst but lets the scraper skip ahead instead of
  # starving the rest of the catalog. 429/503 use the same ladder.
  # Cooldown observed on the upstream Cloudflare Worker: a paginated
  # token issued by page N requires ~30s before page N+1 succeeds.
  # The previous 2s/4s/8s ladder retried while the token was still in
  # cooldown, so every attempt burned the token without giving the
  # worker time to recover. 30s base + exponential keeps the first
  # retry at the cooldown boundary; later retries fan out to 60s, 120s,
  # 240s — total worst-case ~8 min per page, which is fine for a
  # background sync.
  @rate_limit_base_delay :timer.seconds(30)
  @max_rate_limit_retries 4

  @doc """
  Lists the contents of a folder in the GIndex (single page).

  Can be called with:
  - `list_folder(path)` - auto-selects best endpoint
  - `list_folder(path, opts)` - auto-selects endpoint with options
  - `list_folder(base_url, path)` - uses specific endpoint
  - `list_folder(base_url, path, opts)` - uses specific endpoint with options

  ## Examples

      iex> Client.list_folder("/1:/Filmes/")
      {:ok, [%{name: "Movie Name", type: :folder, path: "/1:/Filmes/Movie/"}]}
  """
  def list_folder(path_or_base_url, path_or_opts \\ [])

  def list_folder(path, opts) when is_binary(path) and is_list(opts) do
    # Use smart endpoint selection based on :list operation health
    case get_best_endpoint_for(:list) do
      {:ok, base_url} ->
        list_folder(base_url, path, opts)

      {:error, reason} ->
        {:error, reason}
    end
  end

  def list_folder(base_url, path) when is_binary(base_url) and is_binary(path) do
    list_folder(base_url, path, [])
  end

  def list_folder(base_url, path, opts)
      when is_binary(base_url) and is_binary(path) and is_list(opts) do
    page_token = Keyword.get(opts, :page_token)
    page_index = Keyword.get(opts, :page_index, 0)

    body =
      Jason.encode!(%{
        id: "",
        type: "folder",
        password: "",
        page_token: page_token,
        page_index: page_index
      })

    url = join_url(base_url, path)

    case do_request(:post, url, body, base_url) do
      {:ok, %{status: 200, body: response_body}} ->
        parse_folder_response(response_body, base_url, path)

      {:ok, %{status: status}} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Lists ALL contents of a folder, handling pagination automatically.
  Automatically uses the best available endpoint.
  """
  def list_folder_all(path) do
    case EndpointManager.get_endpoint() do
      {:ok, base_url} ->
        list_folder_all(base_url, path)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Lists ALL contents of a folder using a specific base URL.
  GIndex pagination requires BOTH page_token AND page_index to be incremented.

  Single-flight on `{base_url, path}`: concurrent callers requesting the
  same listing block on the leader's result instead of opening parallel
  paginated walks against the same upstream. Without this, two scan
  roots (or a re-trigger before the first finished) hammer the same
  Cloudflare Worker token bucket and cause the cascading 500s we saw in
  production.
  """
  def list_folder_all(base_url, path) when is_binary(base_url) do
    key = {:list_folder_all, base_url, path}

    SingleFlight.execute(key, fn ->
      list_folder_paginated(base_url, path, nil, 0, [])
    end)
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

    url = join_url(base_url, path)

    case do_request(:post, url, body, base_url) do
      {:ok, %{status: 200, body: response_body}} ->
        case parse_folder_response_with_token(response_body, base_url, path) do
          {:ok, items, nil} ->
            # No more pages
            {:ok, acc ++ items}

          {:ok, items, next_token} ->
            # More pages to fetch - increment page_index
            # Delay between pages to avoid rate limiting (60s + jitter)
            Logger.debug("[GIndex] Fetching page #{page_index + 1}...")
            Process.sleep(60_000 + :rand.uniform(5_000))
            list_folder_paginated(base_url, path, next_token, page_index + 1, acc ++ items)

          {:error, reason} ->
            {:error, reason}
        end

      {:ok, %{status: status}} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Gets the download URL for a file.
  The GIndex generates signed URLs with expiration.

  ## Examples

      iex> Client.get_download_url("/1:/Filmes/movie.mkv")
      {:ok, "https://example.workers.dev/download.aspx?file=TOKEN&expiry=...&mac=..."}
  """
  def get_download_url(file_path) do
    case EndpointManager.get_endpoint() do
      {:ok, base_url} ->
        get_download_url(base_url, file_path)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Gets the download URL for a file using a specific base URL.
  """
  def get_download_url(base_url, file_path) when is_binary(base_url) do
    url = join_url(base_url, file_path)

    body =
      Jason.encode!(%{
        id: "",
        type: "file",
        password: ""
      })

    case do_request(:post, url, body, base_url) do
      {:ok, %{status: 200, body: response_body}} ->
        extract_download_link(response_body, base_url)

      {:ok, %{status: status}} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp extract_download_link(body, base_url) when is_map(body) do
    case body do
      %{"link" => link} when is_binary(link) and link != "" ->
        # The link is a relative path like /download.aspx?file=...
        {:ok, join_url(base_url, link)}

      _ ->
        {:error, :download_url_not_found}
    end
  end

  defp extract_download_link(body, base_url) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, data} -> extract_download_link(data, base_url)
      {:error, _} -> {:error, :invalid_json_response}
    end
  end

  @doc """
  Gets file info including size and modified date.
  """
  def get_file_info(file_path) do
    case EndpointManager.get_endpoint() do
      {:ok, base_url} ->
        get_file_info(base_url, file_path)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Gets file info using a specific base URL.
  """
  def get_file_info(base_url, file_path) when is_binary(base_url) do
    url = join_url(base_url, file_path)

    case do_request(:head, url, nil, base_url) do
      {:ok, %{status: 200, headers: headers}} ->
        {:ok,
         %{
           size: get_header(headers, "content-length") |> parse_int(),
           content_type: get_header(headers, "content-type"),
           modified: get_header(headers, "last-modified")
         }}

      {:ok, %{status: status}} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Gets the current base URL from the EndpointManager.
  Useful for scraper and other modules that need to know the current endpoint.
  """
  def get_base_url do
    EndpointManager.get_endpoint()
  end

  @doc """
  Gets the best endpoint for a specific operation type.
  Uses HealthTracker to select endpoints based on per-operation health status.
  Falls back to EndpointManager if HealthTracker is unavailable.
  """
  def get_best_endpoint_for(operation) when operation in [:list, :stream, :file_info] do
    case EndpointManager.get_all_endpoints() do
      {:ok, [_ | _] = endpoints} ->
        # Convert to format expected by HealthTracker
        endpoints_list =
          Enum.map(endpoints, fn %{name: name, url: url, priority: priority} ->
            {name, url, priority}
          end)

        # Get best endpoint for this operation based on health
        case HealthTracker.get_best_endpoint_for(endpoints_list, operation) do
          {_name, url, _priority} -> {:ok, url}
          nil -> EndpointManager.get_endpoint()
        end

      _ ->
        # Fallback to default selection
        EndpointManager.get_endpoint()
    end
  end

  def get_best_endpoint_for(_operation) do
    EndpointManager.get_endpoint()
  end

  # Private functions

  defp do_request(method, url, body, base_url, opts \\ []) do
    do_request_with_retry(method, url, body, base_url, opts, 0, 0)
  end

  defp do_request_with_retry(method, url, body, base_url, opts, attempt, rate_limit_attempt) do
    # Respect the upstream (Google Drive / Cloudflare Worker) rate budget
    # before we even open the socket. `Pacer.acquire/1` blocks with jitter
    # until a global token is available — this is what keeps 4 parallel
    # workers from stampeding the worker.
    case Pacer.acquire(:gdrive) do
      :ok -> :ok
      {:error, :timeout} -> Logger.warning("[GIndex Client] pacer timeout, proceeding anyway")
    end

    case Req.request(build_request_opts(method, url, body, opts)) do
      {:ok, response} ->
        handle_request_response(
          response,
          method,
          url,
          body,
          base_url,
          opts,
          attempt,
          rate_limit_attempt
        )

      {:error, %Req.TransportError{reason: reason}} when attempt < @max_retries ->
        retry_transport_error(
          reason,
          method,
          url,
          body,
          base_url,
          opts,
          attempt,
          rate_limit_attempt
        )

      {:error, reason} ->
        EndpointManager.report_error(base_url)
        {:error, reason}
    end
  end

  defp build_request_opts(method, url, body, opts) do
    req_opts = [
      method: method,
      url: url,
      headers: build_headers(method),
      receive_timeout: Keyword.get(opts, :timeout, @default_timeout),
      redirect: Keyword.get(opts, :follow_redirects, true),
      finch: Streamix.Finch
    ]

    if body, do: Keyword.put(req_opts, :body, body), else: req_opts
  end

  defp handle_request_response(
         response,
         method,
         url,
         body,
         base_url,
         opts,
         attempt,
         rate_limit_attempt
       ) do
    result =
      handle_response(response, method, url, body, base_url, opts, attempt, rate_limit_attempt)

    report_request_result(base_url, detect_operation(url, body), result)
    result
  end

  defp report_request_result(base_url, operation, {:ok, %{status: 200}}) do
    EndpointManager.report_success(base_url)
    HealthTracker.record_success(base_url, operation)
  end

  defp report_request_result(base_url, operation, {:ok, %{status: status, body: resp_body}})
       when status >= 500 do
    error_type = detect_error_type(resp_body)
    EndpointManager.report_error(base_url)
    HealthTracker.record_error(base_url, operation, error_type)
  end

  defp report_request_result(base_url, operation, {:error, reason}) do
    EndpointManager.report_error(base_url)
    HealthTracker.record_error(base_url, operation, reason)
  end

  defp report_request_result(_base_url, _operation, _result), do: :ok

  defp retry_transport_error(
         reason,
         method,
         url,
         body,
         base_url,
         opts,
         attempt,
         rate_limit_attempt
       ) do
    Logger.warning("[GIndex] Request failed (attempt #{attempt + 1}): #{inspect(reason)}")

    if reason in [:nxdomain, :timeout] do
      :inet_db.clear_cache()
    end

    Process.sleep(@retry_delay)
    do_request_with_retry(method, url, body, base_url, opts, attempt + 1, rate_limit_attempt)
  end

  # Handle rate limiting (429) and service unavailable (503) with exponential backoff
  defp handle_response(
         %{status: status},
         method,
         url,
         body,
         base_url,
         opts,
         attempt,
         rate_limit_attempt
       )
       when status in [429, 503] and rate_limit_attempt < @max_rate_limit_retries do
    base_delay = (@rate_limit_base_delay * :math.pow(2, rate_limit_attempt)) |> round()
    jitter = :rand.uniform(2000)
    delay = base_delay + jitter

    Logger.warning(
      "[GIndex] Rate limited (#{status}), waiting #{div(delay, 1000)}s before retry " <>
        "(attempt #{rate_limit_attempt + 1}/#{@max_rate_limit_retries})"
    )

    Process.sleep(delay)
    do_request_with_retry(method, url, body, base_url, opts, attempt, rate_limit_attempt + 1)
  end

  # Handle 500 errors - check for auth errors, otherwise report to EndpointManager
  defp handle_response(
         %{status: 500, body: resp_body} = response,
         method,
         url,
         body,
         base_url,
         opts,
         attempt,
         rate_limit_attempt
       )
       when rate_limit_attempt < @max_rate_limit_retries do
    body_str = if is_binary(resp_body), do: resp_body, else: inspect(resp_body)
    is_auth_error = auth_error?(body_str)

    if is_auth_error do
      Logger.error("[GIndex] Authentication/Token error (500): #{String.slice(body_str, 0, 500)}")
      # Don't retry auth errors - return immediately
      {:ok, response}
    else
      # Report error to EndpointManager - it will handle circuit breaking
      EndpointManager.report_error(base_url)

      # Check if we should try fallback endpoint
      case EndpointManager.get_endpoint() do
        {:ok, new_base_url} when new_base_url != base_url ->
          # We have a different (fallback) endpoint available
          Logger.info("[GIndex] Switching to fallback endpoint: #{new_base_url}")

          # Rebuild URL with new base
          path = String.replace_prefix(url, base_url, "")
          new_url = new_base_url <> path

          # Try with new endpoint
          do_request_with_retry(method, new_url, body, new_base_url, opts, attempt, 0)

        _ ->
          # No fallback or same endpoint - retry with backoff
          base_delay = (@rate_limit_base_delay * :math.pow(2, rate_limit_attempt)) |> round()
          jitter = :rand.uniform(2000)
          delay = base_delay + jitter

          Logger.warning(
            "[GIndex] Server error (500), body: #{String.slice(body_str, 0, 200)}... " <>
              "waiting #{div(delay, 1000)}s before retry (attempt #{rate_limit_attempt + 1}/#{@max_rate_limit_retries})"
          )

          Process.sleep(delay)

          do_request_with_retry(
            method,
            url,
            body,
            base_url,
            opts,
            attempt,
            rate_limit_attempt + 1
          )
      end
    end
  end

  defp handle_response(
         response,
         _method,
         _url,
         _body,
         _base_url,
         _opts,
         _attempt,
         _rate_limit_attempt
       ) do
    {:ok, response}
  end

  # Check if error response indicates auth/token issue
  defp auth_error?(body) when is_binary(body) do
    body_lower = String.downcase(body)

    String.contains?(body_lower, "token") or
      String.contains?(body_lower, "auth") or
      String.contains?(body_lower, "expired") or
      String.contains?(body_lower, "invalid") or
      String.contains?(body_lower, "unauthorized") or
      String.contains?(body_lower, "forbidden") or
      String.contains?(body_lower, "access denied")
  end

  defp auth_error?(_), do: false

  defp build_headers(:post) do
    [
      {"content-type", "application/json"},
      {"accept", "application/json, text/plain, */*"},
      {"user-agent", "Mozilla/5.0 (compatible; Streamix/1.0)"}
    ]
  end

  defp build_headers(_method) do
    [
      {"accept", "*/*"},
      {"user-agent", "Mozilla/5.0 (compatible; Streamix/1.0)"}
    ]
  end

  defp parse_folder_response(body, base_url, current_path) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, data} ->
        parse_folder_data(data, base_url, current_path)

      {:error, _} ->
        {:error, :invalid_json_response}
    end
  end

  defp parse_folder_response(body, base_url, current_path) when is_map(body) do
    parse_folder_data(body, base_url, current_path)
  end

  defp parse_folder_response_with_token(body, base_url, current_path) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, data} ->
        parse_folder_data_with_token(data, base_url, current_path)

      {:error, _} ->
        {:error, :invalid_json_response}
    end
  end

  defp parse_folder_response_with_token(body, base_url, current_path) when is_map(body) do
    parse_folder_data_with_token(body, base_url, current_path)
  end

  defp parse_folder_data(%{"data" => %{"files" => files}}, base_url, current_path)
       when is_list(files) do
    items = Enum.map(files, &parse_file_item(&1, base_url, current_path))
    {:ok, items}
  end

  defp parse_folder_data(%{"files" => files}, base_url, current_path) when is_list(files) do
    items = Enum.map(files, &parse_file_item(&1, base_url, current_path))
    {:ok, items}
  end

  defp parse_folder_data(data, base_url, current_path) do
    files = extract_files_from_response(data)
    items = Enum.map(files, &parse_file_item(&1, base_url, current_path))
    {:ok, items}
  end

  defp parse_folder_data_with_token(%{"data" => data}, base_url, current_path)
       when is_map(data) do
    files = Map.get(data, "files", [])
    next_token = Map.get(data, "nextPageToken")
    items = Enum.map(files, &parse_file_item(&1, base_url, current_path))
    {:ok, items, next_token}
  end

  defp parse_folder_data_with_token(%{"files" => files} = data, base_url, current_path)
       when is_list(files) do
    next_token = Map.get(data, "nextPageToken")
    items = Enum.map(files, &parse_file_item(&1, base_url, current_path))
    {:ok, items, next_token}
  end

  defp parse_folder_data_with_token(data, base_url, current_path) do
    files = extract_files_from_response(data)
    next_token = extract_next_page_token(data)
    items = Enum.map(files, &parse_file_item(&1, base_url, current_path))
    {:ok, items, next_token}
  end

  defp extract_files_from_response(%{"data" => data}) when is_map(data) do
    Map.get(data, "files", [])
  end

  defp extract_files_from_response(%{"files" => files}) when is_list(files), do: files
  defp extract_files_from_response(_), do: []

  defp extract_next_page_token(%{"data" => data}) when is_map(data) do
    Map.get(data, "nextPageToken")
  end

  defp extract_next_page_token(%{"nextPageToken" => token}), do: token
  defp extract_next_page_token(_), do: nil

  defp parse_file_item(item, _base_url, current_path) do
    name = item["name"] || item["title"] || ""
    mime_type = item["mimeType"] || item["mime_type"] || ""
    size = item["size"] || 0

    type = determine_file_type(mime_type, name)
    path = build_file_path(current_path, name, type)

    %{
      name: String.trim_trailing(name, "/"),
      type: type,
      path: path,
      size: parse_size(size),
      mime_type: mime_type,
      modified: item["modifiedTime"] || item["modified_time"]
    }
  end

  defp determine_file_type(mime_type, name) do
    if mime_type == "application/vnd.google-apps.folder" or String.ends_with?(name, "/") do
      :folder
    else
      :file
    end
  end

  defp build_file_path(current_path, name, :folder) do
    Path.join(current_path, name) <> "/"
  end

  defp build_file_path(current_path, name, :file) do
    Path.join(current_path, name)
  end

  defp parse_size(size) when is_integer(size), do: size
  defp parse_size(size) when is_binary(size), do: parse_int(size)
  defp parse_size(_), do: 0

  defp parse_int(nil), do: nil
  defp parse_int(str) when is_binary(str), do: String.to_integer(str)
  defp parse_int(num) when is_integer(num), do: num

  defp get_header(headers, name) do
    name_lower = String.downcase(name)

    Enum.find_value(headers, fn {key, value} ->
      if String.downcase(key) == name_lower, do: value
    end)
  end

  # URL helper function - joins base URL with path properly and encodes special characters
  defp join_url(base_url, path) do
    base = String.trim_trailing(base_url, "/")
    path_part = if String.starts_with?(path, "/"), do: path, else: "/" <> path

    # If path already has query params (download URLs), don't encode
    if String.contains?(path_part, "?") do
      base <> path_part
    else
      encoded_path = encode_path(path_part)
      base <> encoded_path
    end
  end

  # Encode URL path while preserving / and drive letter : (like "1:")
  defp encode_path(path) do
    path
    |> String.split("/")
    |> Enum.with_index()
    |> Enum.map_join("/", fn {segment, index} ->
      if index <= 1 and Regex.match?(~r/^\d+:$/, segment) do
        segment
      else
        URI.encode(segment, &uri_char?/1)
      end
    end)
  end

  # Characters allowed in URL path segments (RFC 3986)
  defp uri_char?(char) do
    char in ?0..?9 or char in ?a..?z or char in ?A..?Z or char in ~c"-._~!$&'()*+,;=@"
  end

  # Detect operation type from URL and body for health tracking
  defp detect_operation(url, body) do
    cond do
      # Stream/download operations
      String.contains?(url, "?a=") or String.contains?(url, "download") ->
        :stream

      # File info operations (getting direct links)
      is_binary(body) and String.contains?(body, "\"type\":\"file\"") ->
        :file_info

      # Default: folder listing
      true ->
        :list
    end
  end

  # Detect specific error types from response body
  defp detect_error_type(body) when is_binary(body) do
    cond do
      String.contains?(body, "TypeError") -> :javascript_error
      String.contains?(body, "Cannot read properties") -> :javascript_error
      String.contains?(body, "rate limit") -> :rate_limit
      String.contains?(body, "quota") -> :quota_exceeded
      true -> :unknown_server_error
    end
  end

  defp detect_error_type(_), do: :unknown
end
