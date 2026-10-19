defmodule Streamix.Hls.Fetch do
  @moduledoc """
  Bounded upstream requests for the HLS gateways.

  Every request goes out through Req with automatic redirects and retries
  disabled. Redirects are followed here, by hand, so the SSRF validator runs
  on every hop before it is requested — including the first one — and a
  chain longer than five hops fails instead of looping. Bodies are collected
  under a 32 MiB cap, and only the response headers a media relay needs
  survive (`Content-Type`, `Content-Length`, `Content-Range`,
  `Accept-Ranges`).

  Callers pass `:http_options`, merged in front of the fixed options, which
  is how tests route requests to a `Req.Test` stub.
  """

  alias Streamix.Security.UrlValidator

  @max_body 32 * 1024 * 1024
  @max_redirects 5
  @idle_timeout 15_000
  @response_headers ~w(content-type content-length content-range accept-ranges)
  @redirect_statuses [301, 302, 303, 307, 308]

  @doc """
  Fetches `url` with `headers`, following at most five validated redirects.

  `headers` are sent unchanged unless `:headers_for_url` (arity 2) scopes them per hop. Options: `:method` (`:get` or
  `:head`), `:range` (a single byte range, sent upstream as-is),
  `:http_options`, and `:timeout` — the total deadline of each hop in
  milliseconds (default 15 s). The idle time between two reads is capped at
  15 s whatever the total, so a slow but steady transfer may run longer than
  that while a stalled one still fails.

  Returns `{:ok, %{status: 200 | 206, body:, url: final_url, headers:}}` or
  `{:error, reason}` where `reason` is `:unsafe_url`, `:upstream_not_found`
  (404), `:playback_restart_required` (401/403/410), `:invalid_range` (416),
  `:response_too_large` or `:upstream_unavailable`.
  """
  def fetch(url, headers, opts \\ []), do: fetch(url, headers, opts, 0)

  defp fetch(_url, _headers, _opts, redirects) when redirects > @max_redirects,
    do: {:error, :upstream_unavailable}

  defp fetch(url, headers, opts, redirects) do
    timeout = Keyword.get(opts, :timeout, @idle_timeout)

    with :ok <- UrlValidator.validate_url(url),
         {:ok, response} <-
           request(
             [
               method: Keyword.get(opts, :method, :get),
               url: url,
               headers: hop_headers(url, headers, opts) ++ range_header(opts),
               receive_timeout: min(timeout, @idle_timeout),
               request_timeout: timeout,
               max_body: @max_body
             ],
             Keyword.get(opts, :http_options, [])
           ) do
      handle_response(response, url, headers, opts, redirects)
    end
  end

  defp handle_response(%{status: status} = response, url, headers, opts, redirects)
       when status in @redirect_statuses do
    with {:ok, target} <- redirect_target(response, url) do
      fetch(target, headers, opts, redirects + 1)
    end
  end

  defp handle_response(%{status: status} = response, url, _headers, _opts, _redirects)
       when status in [200, 206] do
    {:ok,
     %{
       status: status,
       body: response.body,
       url: url,
       headers: response_headers(response)
     }}
  end

  defp handle_response(response, _url, _headers, _opts, _redirects), do: status_error(response)

  @doc """
  Runs one request with the body collected under `:max_body` bytes.

  `opts` are Req options plus the required `:max_body` and
  `:receive_timeout`; the total request deadline is `:request_timeout`, and
  equals the receive timeout when that is not given. Transport failures
  collapse to `:upstream_unavailable`, so no exception (and no URL inside
  one) ever reaches a caller or a log line.
  """
  def request(opts, http_options \\ []) do
    {max_body, opts} = Keyword.pop!(opts, :max_body)
    opts = Keyword.put_new(opts, :request_timeout, Keyword.fetch!(opts, :receive_timeout))

    # A named pool carries its own connect timeout (Req refuses both).
    connect =
      if Keyword.has_key?(http_options, :finch),
        do: [],
        else: [connect_options: [timeout: 5_000]]

    options =
      base_options(http_options) ++
        connect ++
        [
          into: fn {:data, data}, {request, response} ->
            body = response.body || ""

            if byte_size(body) + byte_size(data) <= max_body do
              {:cont, {request, %{response | body: body <> data}}}
            else
              {:halt, {request, Req.Response.put_private(response, :body_too_large, true)}}
            end
          end
        ] ++ opts

    case Req.request(options) do
      {:ok, response} ->
        if response.private[:body_too_large],
          do: {:error, :response_too_large},
          else: {:ok, response}

      {:error, _} ->
        {:error, :upstream_unavailable}
    end
  end

  @doc "Req options shared by every gateway request: no automatic redirect, retry or decoding."
  def base_options(http_options \\ []) do
    http_options ++ [redirect: false, retry: false, decode_body: false, compressed: false]
  end

  @doc "Whether `status` is a redirect the gateways follow by hand."
  def redirect_status?(status), do: status in @redirect_statuses

  @doc "The absolute `Location` of a redirect response, resolved against `url`."
  def redirect_target(response, url) do
    with location when is_binary(location) <-
           List.first(Map.get(response.headers, "location", [])),
         {:ok, target} <- merge_url(url, location) do
      {:ok, target}
    else
      _ -> {:error, :upstream_unavailable}
    end
  end

  @doc "The relayable subset of an upstream response's headers."
  def response_headers(response), do: Map.take(response.headers, @response_headers)

  @doc """
  Classifies an upstream error status.

  401, 403 and 410 mean the source stopped authorizing this session, so the
  caller should invalidate it rather than retry the same URL.
  """
  def status_error(%{status: status}) when status in [401, 403, 410],
    do: {:error, :playback_restart_required}

  def status_error(%{status: 404}), do: {:error, :upstream_not_found}
  def status_error(%{status: 416}), do: {:error, :invalid_range}
  def status_error(_response), do: {:error, :upstream_unavailable}

  @doc """
  Resolves `reference` against `base` with URI semantics.

  A child path does not inherit the base's query, while a query-only
  reference keeps the base path. Existing query values are not re-encoded.
  Fragments and malformed references are refused.
  """
  def merge_url(base, reference) do
    case URI.new(reference) do
      {:ok, %URI{fragment: nil} = uri} -> {:ok, base |> URI.merge(uri) |> URI.to_string()}
      _ -> {:error, :unsafe_url}
    end
  rescue
    ArgumentError -> {:error, :unsafe_url}
  end

  defp hop_headers(url, headers, opts) do
    case Keyword.get(opts, :headers_for_url) do
      fun when is_function(fun, 2) -> fun.(url, headers)
      _ -> headers
    end
  end

  defp range_header(opts) do
    case Keyword.get(opts, :range) do
      nil -> []
      range -> [{"range", range}]
    end
  end
end
