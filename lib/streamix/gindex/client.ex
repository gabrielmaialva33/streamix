defmodule Streamix.Gindex.Client do
  @moduledoc """
  HTTP client for GIndex (Google Drive Index) servers.

  GIndex uses a JavaScript-based frontend that makes POST requests to fetch
  folder contents. This client mimics those requests.

  ## Multi-Endpoint Failover

  This client uses EndpointManager for automatic failover between multiple
  GIndex endpoints. If one endpoint starts failing, requests are automatically
  routed to healthy fallback endpoints.
  """

  alias Streamix.Gindex.EndpointManager
  alias Streamix.Gindex.EndpointPolicy
  alias Streamix.Gindex.HealthTracker
  alias Streamix.Gindex.Pagination
  alias Streamix.Gindex.Response
  alias Streamix.Gindex.SingleFlight
  alias Streamix.Gindex.Transport
  alias Streamix.Gindex.Url

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

    url = Url.join(base_url, path)

    case Transport.request(:post, url, body, base_url) do
      {:ok, %{status: 200, body: response_body}} ->
        Response.parse_folder(response_body, base_url, path)

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

  GIndex 2.3.6 expects `nextPageToken` together with the matching
  incremented `page_index`. If a listing still fails partway through,
  it restarts from page zero on the next endpoint because cursors
  aren't reliably portable between all GIndex deployments.

  Single-flight on `{base_url, path}`: concurrent callers requesting the
  same listing block on the leader's result instead of opening parallel
  paginated walks against the same upstream. Without this, two scan
  roots (or a re-trigger before the first finished) hammer the same
  Cloudflare Worker token bucket and cause the cascading 500s we saw in
  production.
  """
  def list_folder_all(base_url, path) when is_binary(base_url) do
    endpoints = listing_endpoints(base_url)
    key = {:list_folder_all, endpoints, path}

    SingleFlight.execute(key, fn ->
      Pagination.list_folder_all(endpoints, path)
    end)
  end

  @doc """
  Gets the download URL for a file.
  The GIndex generates signed URLs with expiration.

  ## Examples

      iex> Client.get_download_url("/1:/Filmes/movie.mkv")
      {:ok, "https://example.workers.dev/download.aspx?file=TOKEN&expiry=...&mac=..."}
  """
  def get_download_url(file_path) do
    EndpointPolicy.stream_url()
    |> get_download_url(file_path)
  end

  @doc """
  Gets the download URL for a file using a specific base URL.
  """
  def get_download_url(base_url, file_path) when is_binary(base_url) do
    url = Url.join(base_url, file_path)

    body =
      Jason.encode!(%{
        id: "",
        type: "file",
        password: ""
      })

    case Transport.request(:post, url, body, base_url) do
      {:ok, %{status: 200, body: response_body}} ->
        Response.extract_download_link(response_body, base_url)

      {:ok, %{status: status}} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Gets file info including size and modified date.
  """
  def get_file_info(file_path) do
    EndpointPolicy.stream_url()
    |> get_file_info(file_path)
  end

  @doc """
  Gets file info using a specific base URL.
  """
  def get_file_info(base_url, file_path) when is_binary(base_url) do
    url = Url.join(base_url, file_path)

    case Transport.request(:head, url, nil, base_url) do
      {:ok, %{status: 200, headers: headers}} ->
        {:ok, Response.file_info(headers)}

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

  defp listing_endpoints(preferred_url) do
    fallbacks =
      case Process.whereis(EndpointManager) do
        nil ->
          []

        _pid ->
          case EndpointManager.get_all_endpoints() do
            {:ok, endpoints} -> Enum.map(endpoints, & &1.url)
            _ -> []
          end
      end

    [preferred_url | fallbacks]
    |> Enum.map(&String.trim_trailing(&1, "/"))
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end
end
