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

  @default_timeout :timer.seconds(30)
  @retry_delay :timer.seconds(5)
  @max_retries 3
  # Conservative rate limit handling - start with 30s to fully recover
  @rate_limit_base_delay :timer.seconds(30)
  @max_rate_limit_retries 5

  @doc """
  Lists the contents of a folder in the GIndex (single page).
  Automatically uses the best available endpoint.

  ## Examples

      iex> Client.list_folder("/1:/Filmes/")
      {:ok, [%{name: "Movie Name", type: :folder, path: "/1:/Filmes/Movie/"}]}
  """
  def list_folder(path, opts \\ []) do
    case EndpointManager.get_endpoint() do
      {:ok, base_url} ->
        list_folder(base_url, path, opts)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Lists the contents of a folder using a specific base URL.
  """
  def list_folder(base_url, path, opts) when is_binary(base_url) do
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
  """
  def list_folder_all(base_url, path) when is_binary(base_url) do
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

  # Private functions

  defp do_request(method, url, body, base_url, opts \\ []) do
    do_request_with_retry(method, url, body, base_url, opts, 0, 0)
  end

  defp do_request_with_retry(method, url, body, base_url, opts, attempt, rate_limit_attempt) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    follow_redirects = Keyword.get(opts, :follow_redirects, true)

    req_opts = [
      method: method,
      url: url,
      headers: build_headers(method),
      receive_timeout: timeout,
      redirect: follow_redirects,
      finch: Streamix.Finch
    ]

    req_opts =
      if body do
        Keyword.put(req_opts, :body, body)
      else
        req_opts
      end

    case Req.request(req_opts) do
      {:ok, response} ->
        result = handle_response(response, method, url, body, base_url, opts, attempt, rate_limit_attempt)

        # Report success/failure to EndpointManager
        case result do
          {:ok, %{status: 200}} ->
            EndpointManager.report_success(base_url)

          {:ok, %{status: status}} when status >= 500 ->
            EndpointManager.report_error(base_url)

          {:error, _} ->
            EndpointManager.report_error(base_url)

          _ ->
            :ok
        end

        result

      {:error, %Req.TransportError{reason: reason}} when attempt < @max_retries ->
        Logger.warning("[GIndex] Request failed (attempt #{attempt + 1}): #{inspect(reason)}")
        Process.sleep(@retry_delay)
        do_request_with_retry(method, url, body, base_url, opts, attempt + 1, rate_limit_attempt)

      {:error, reason} ->
        EndpointManager.report_error(base_url)
        {:error, reason}
    end
  end

  # Handle rate limiting (429) and service unavailable (503) with exponential backoff
  defp handle_response(%{status: status}, method, url, body, base_url, opts, attempt, rate_limit_attempt)
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
  defp handle_response(%{status: 500, body: resp_body} = response, method, url, body, base_url, opts, attempt, rate_limit_attempt)
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
      endpoint_result = EndpointManager.get_endpoint()
      Logger.debug("[GIndex] Current base_url: #{base_url}, get_endpoint result: #{inspect(endpoint_result)}")

      case endpoint_result do
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
          do_request_with_retry(method, url, body, base_url, opts, attempt, rate_limit_attempt + 1)
      end
    end
  end

  defp handle_response(response, _method, _url, _body, _base_url, _opts, _attempt, _rate_limit_attempt) do
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
end
