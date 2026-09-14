defmodule Streamix.Embedplay.HTTP do
  @moduledoc false

  alias Streamix.Embedplay
  alias Streamix.Security.UrlValidator

  @max_body 32 * 1024 * 1024
  @forward_headers ~w(user-agent referer origin)
  @response_headers ~w(content-type content-length content-range accept-ranges)

  def resolve(movie) do
    url = Embedplay.config(:resolver_url)
    secret = Embedplay.config(:resolver_token)

    if is_binary(url) and is_binary(secret) and secret != "" do
      request = [
        method: :post,
        url: String.trim_trailing(url, "/") <> "/resolve",
        auth: {:bearer, secret},
        json: %{tmdb_id: movie.tmdb_id, imdb_id: movie.imdb_id, audio: "dubbed"},
        receive_timeout: Embedplay.config(:resolve_timeout_ms, 45_000),
        max_body: 64 * 1024
      ]

      case request(request) do
        {:ok, response} -> classify_resolution(response)
        _ -> {:error, :stream_resolution_failed}
      end
    else
      {:error, :provider_disabled}
    end
  end

  def fetch(url, headers, opts \\ []), do: fetch(url, headers, opts, 0)

  defp fetch(_url, _headers, _opts, redirects) when redirects > 5,
    do: {:error, :upstream_unavailable}

  defp fetch(url, headers, opts, redirects) do
    with :ok <- UrlValidator.validate_url(url),
         {:ok, response} <-
           request(
             method: Keyword.get(opts, :method, :get),
             url: url,
             headers: headers ++ range_header(opts),
             receive_timeout: 15_000,
             max_body: @max_body
           ) do
      handle_response(response, url, headers, opts, redirects)
    end
  end

  defp handle_response(%{status: status} = response, url, headers, opts, redirects)
       when status in [301, 302, 303, 307, 308] do
    with location when is_binary(location) <-
           List.first(Map.get(response.headers, "location", [])),
         {:ok, target} <- merge_url(url, location) do
      fetch(target, headers, opts, redirects + 1)
    else
      _ -> {:error, :upstream_unavailable}
    end
  end

  defp handle_response(%{status: status} = response, url, _headers, _opts, _redirects)
       when status in [200, 206] do
    {:ok,
     %{
       status: status,
       body: response.body,
       url: url,
       headers: Map.take(response.headers, @response_headers)
     }}
  end

  defp handle_response(%{status: status}, _url, _headers, _opts, _redirects)
       when status in [401, 403, 410], do: {:error, :playback_restart_required}

  defp handle_response(%{status: 404}, _url, _headers, _opts, _redirects),
    do: {:error, :upstream_not_found}

  defp handle_response(%{status: 416}, _url, _headers, _opts, _redirects),
    do: {:error, :invalid_range}

  defp handle_response(_, _url, _headers, _opts, _redirects), do: {:error, :upstream_unavailable}

  def merge_url(base, reference) do
    case URI.new(reference) do
      {:ok, %URI{fragment: nil} = uri} -> {:ok, base |> URI.merge(uri) |> URI.to_string()}
      _ -> {:error, :unsafe_url}
    end
  rescue
    ArgumentError -> {:error, :unsafe_url}
  end

  defp classify_resolution(%{status: 200, body: body}), do: decode_resolution(body)
  defp classify_resolution(%{status: 503}), do: {:error, :provider_capacity_exhausted}
  defp classify_resolution(%{status: 504}), do: {:error, :upstream_timeout}
  defp classify_resolution(%{status: 401}), do: {:error, :provider_disabled}
  defp classify_resolution(%{body: body}), do: resolution_error(body)

  # The resolver answers 502 for several distinct situations and the status
  # alone cannot tell them apart, so read the body. `stream_unavailable` is
  # NOT a statement that the title has no source: the resolver raises it
  # whenever extraction failed, and production logs show it failing at the
  # selection stage for a title that played minutes earlier. It is separated
  # here only so the case is countable and can carry its own backoff —
  # everything below stays retryable, because treating an extraction failure
  # as a dead title would take working content out of the catalogue.
  defp resolution_error(body) do
    case Jason.decode(body) do
      {:ok, %{"error" => %{"code" => "stream_unavailable"}}} -> {:error, :no_source_available}
      _ -> {:error, :stream_resolution_failed}
    end
  end

  defp decode_resolution(body) do
    with {:ok, %{"manifest_url" => url} = result} <- Jason.decode(body),
         :ok <- UrlValidator.validate_url(url),
         {:ok, headers} <- safe_headers(Map.get(result, "headers", %{})) do
      {:ok, %{url: url, headers: headers, expires_at: Map.get(result, "expires_at")}}
    else
      _ -> {:error, :stream_resolution_failed}
    end
  end

  defp safe_headers(headers) when is_map(headers) and map_size(headers) <= 8 do
    Enum.reduce_while(headers, {:ok, []}, fn {name, value}, {:ok, acc} ->
      if is_binary(name) and is_binary(value) and String.downcase(name) in @forward_headers and
           byte_size(value) <= 2048 and not String.contains?(value, ["\r", "\n"]) do
        {:cont, {:ok, [{String.downcase(name), value} | acc]}}
      else
        {:halt, {:error, :unsupported_headers}}
      end
    end)
  end

  defp safe_headers(_), do: {:error, :unsupported_headers}

  defp range_header(opts) do
    case Keyword.get(opts, :range) do
      nil -> []
      range -> [{"range", range}]
    end
  end

  defp request(opts) do
    {max_body, opts} = Keyword.pop!(opts, :max_body)
    opts = Keyword.put(opts, :request_timeout, Keyword.fetch!(opts, :receive_timeout))

    options =
      Embedplay.config(:http_options, []) ++
        [
          redirect: false,
          retry: false,
          decode_body: false,
          compressed: false,
          connect_options: [timeout: 5_000],
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
end
