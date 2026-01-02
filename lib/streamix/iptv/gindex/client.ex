defmodule Streamix.Iptv.Gindex.Client do
  @moduledoc """
  HTTP client for GIndex (Google Drive Index) servers.

  GIndex uses a JavaScript-based frontend that makes POST requests to fetch
  folder contents. This client mimics those requests.
  """

  require Logger

  @default_timeout :timer.seconds(30)
  @retry_delay :timer.seconds(2)
  @max_retries 3

  @doc """
  Lists the contents of a folder in the GIndex.

  ## Examples

      iex> Client.list_folder("https://example.workers.dev", "/1:/Filmes/")
      {:ok, [%{name: "Movie Name", type: :folder, path: "/1:/Filmes/Movie/"}]}
  """
  def list_folder(base_url, path, opts \\ []) do
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

    case do_request(:post, url, body) do
      {:ok, %{status: 200, body: response_body}} ->
        parse_folder_response(response_body, base_url, path)

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

      iex> Client.get_download_url("https://example.workers.dev", "/1:/Filmes/movie.mkv")
      {:ok, "https://example.workers.dev/download.aspx?file=TOKEN&expiry=...&mac=..."}
  """
  def get_download_url(base_url, file_path) do
    # POST to the file path with type: "file" to get file metadata including download link
    url = join_url(base_url, file_path)

    body =
      Jason.encode!(%{
        id: "",
        type: "file",
        password: ""
      })

    case do_request(:post, url, body) do
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
  def get_file_info(base_url, file_path) do
    url = join_url(base_url, file_path)

    case do_request(:head, url) do
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

  # Private functions

  defp do_request(method, url, body \\ nil, opts \\ []) do
    do_request_with_retry(method, url, body, opts, 0)
  end

  defp do_request_with_retry(method, url, body, opts, attempt) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    follow_redirects = Keyword.get(opts, :follow_redirects, true)

    req_opts = [
      method: method,
      url: url,
      headers: build_headers(method),
      receive_timeout: timeout,
      redirect: follow_redirects
    ]

    req_opts =
      if body do
        Keyword.put(req_opts, :body, body)
      else
        req_opts
      end

    case Req.request(req_opts) do
      {:ok, response} ->
        {:ok, response}

      {:error, %Req.TransportError{reason: reason}} when attempt < @max_retries ->
        Logger.warning("[GIndex] Request failed (attempt #{attempt + 1}): #{inspect(reason)}")
        Process.sleep(@retry_delay)
        do_request_with_retry(method, url, body, opts, attempt + 1)

      {:error, reason} ->
        {:error, reason}
    end
  end

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
        # Response might be HTML, try to parse it
        {:error, :invalid_json_response}
    end
  end

  # Handle case where Req already decoded the JSON
  defp parse_folder_response(body, base_url, current_path) when is_map(body) do
    parse_folder_data(body, base_url, current_path)
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
    # Try to extract files from different response formats
    files = extract_files_from_response(data)
    items = Enum.map(files, &parse_file_item(&1, base_url, current_path))
    {:ok, items}
  end

  defp extract_files_from_response(%{"data" => data}) when is_map(data) do
    Map.get(data, "files", [])
  end

  defp extract_files_from_response(%{"files" => files}) when is_list(files), do: files
  defp extract_files_from_response(_), do: []

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

    # If path already has query params (download URLs), don't encode - it's already a valid URL path
    if String.contains?(path_part, "?") do
      base <> path_part
    else
      # Encode the path, but preserve / and : characters which are valid in GIndex paths
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
      # Only treat as drive letter if it's the first non-empty segment and matches pattern "X:"
      if index <= 1 and Regex.match?(~r/^\d+:$/, segment) do
        # This is a drive letter like "1:", don't encode
        segment
      else
        # Fully encode the segment including any : characters
        URI.encode(segment, &uri_char?/1)
      end
    end)
  end

  # Characters allowed in URL path segments (RFC 3986) - note: : is NOT included
  defp uri_char?(char) do
    char in ?0..?9 or char in ?a..?z or char in ?A..?Z or char in ~c"-._~!$&'()*+,;=@"
  end
end
