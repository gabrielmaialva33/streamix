defmodule Streamix.Embedplay.HTTP do
  @moduledoc false

  alias Streamix.Embedplay
  alias Streamix.Security.UrlValidator

  @max_body 32 * 1024 * 1024
  @forward_headers ~w(user-agent referer origin)
  @response_headers ~w(content-type content-length content-range accept-ranges)
  @redirect_statuses [301, 302, 303, 307, 308]

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

  # `headers` are the resolver-provided, allowlisted request headers. They and
  # the `Range` are sent unchanged on every hop of a redirect chain — for both
  # `fetch/3` and `stream/5` — because the progressive source checks `Referer`
  # on its first host and then redirects to an ephemeral tunnel host. Nothing
  # here adds an `Origin`, which that source answers with 404.
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
       headers: Map.take(response.headers, @response_headers)
     }}
  end

  defp handle_response(response, _url, _headers, _opts, _redirects), do: status_error(response)

  @doc """
  Streams a progressive media body to `sink` as it arrives instead of
  collecting it, so memory per request stays at one socket read however large
  the file is. The sink runs in the calling process, so a client that reads
  slowly delays the next upstream read: backpressure is TCP's own.

  `sink` receives `{:start, status, headers}` once, before the first byte,
  and may still refuse with `{:error, reason}` because nothing was sent yet;
  then `{:data, chunk}` for each non-empty chunk. It answers `{:cont, acc}` or
  `{:halt, acc}`, and halting stops reading upstream (the connection is
  closed, not drained). Redirect and error responses never reach the sink:
  they are followed or classified exactly like `fetch/3`, so the caller can
  still answer with a clean error.

  Returns `{:ok, acc}` once the response has started, `{:error,
  :upstream_aborted, acc}` when the upstream failed after it started, and
  `{:error, reason}` when nothing was sent.
  """
  def stream(url, headers, opts, acc, sink), do: stream(url, headers, opts, acc, sink, 0)

  defp stream(_url, _headers, _opts, _acc, _sink, redirects) when redirects > 5,
    do: {:error, :upstream_unavailable}

  defp stream(url, headers, opts, acc, sink, redirects) do
    with :ok <- UrlValidator.validate_url(url) do
      (base_options() ++
         [
           method: :get,
           url: url,
           headers: headers ++ range_header(opts),
           # The dedicated HTTP/1 media pool: Finch documents no backpressure
           # for HTTP/2 response streaming, and these connections are
           # long-lived, so they stay out of the pool shared by short requests.
           finch: [name: Streamix.StreamFinch, pool_timeout: 5_000],
           # Idle time between upstream reads; the transfer itself may last
           # as long as the movie, so there is no total deadline.
           receive_timeout: 15_000,
           request_timeout: :infinity,
           into: &relay(&1, &2, sink)
         ])
      |> Req.new()
      |> Req.Request.put_private(:embedplay_sink, {:pending, acc})
      |> Req.Request.run_request()
      |> streamed(url, headers, opts, sink, redirects)
    end
  end

  defp relay({:data, data}, {request, %{status: status} = response}, sink)
       when status in [200, 206] do
    with {:cont, acc} <- start_sink(request, response, sink),
         {:cont, acc} <- forward(data, acc, sink) do
      {:cont, {put_sink(request, {:started, acc}), response}}
    else
      {:halt, acc} -> {:halt, {put_sink(request, {:started, acc}), response}}
      {:error, reason} -> {:halt, {put_sink(request, {:refused, reason}), response}}
    end
  end

  # A redirect or error body is never needed, so it is not read at all.
  defp relay({:data, _data}, acc, _sink), do: {:halt, acc}

  defp start_sink(request, response, sink) do
    case request.private.embedplay_sink do
      {:started, acc} -> {:cont, acc}
      {:pending, acc} -> sink.({:start, response.status, response_headers(response)}, acc)
    end
  end

  # An empty chunk would end a chunked client response early.
  defp forward("", acc, _sink), do: {:cont, acc}
  defp forward(data, acc, sink), do: sink.({:data, data}, acc)

  defp put_sink(request, state), do: Req.Request.put_private(request, :embedplay_sink, state)

  defp streamed({request, %Req.Response{} = response}, url, headers, opts, sink, redirects) do
    case request.private.embedplay_sink do
      {:started, acc} -> {:ok, acc}
      {:refused, reason} -> {:error, reason}
      {:pending, acc} -> unstarted(response, url, headers, opts, acc, sink, redirects)
    end
  end

  defp streamed({request, _exception}, _url, _headers, _opts, _sink, _redirects) do
    case request.private.embedplay_sink do
      {:started, acc} -> {:error, :upstream_aborted, acc}
      _ -> {:error, :upstream_unavailable}
    end
  end

  defp unstarted(%{status: status} = response, url, headers, opts, acc, sink, redirects)
       when status in @redirect_statuses do
    with {:ok, target} <- redirect_target(response, url) do
      stream(target, headers, opts, acc, sink, redirects + 1)
    end
  end

  # A successful response with an empty body never reached `relay/3`.
  defp unstarted(%{status: status} = response, _url, _headers, _opts, acc, sink, _redirects)
       when status in [200, 206] do
    case sink.({:start, status, response_headers(response)}, acc) do
      {:error, reason} -> {:error, reason}
      {_action, acc} -> {:ok, acc}
    end
  end

  defp unstarted(response, _url, _headers, _opts, _acc, _sink, _redirects),
    do: status_error(response)

  defp redirect_target(response, url) do
    with location when is_binary(location) <-
           List.first(Map.get(response.headers, "location", [])),
         {:ok, target} <- merge_url(url, location) do
      {:ok, target}
    else
      _ -> {:error, :upstream_unavailable}
    end
  end

  defp response_headers(response), do: Map.take(response.headers, @response_headers)

  defp status_error(%{status: status}) when status in [401, 403, 410],
    do: {:error, :playback_restart_required}

  defp status_error(%{status: 404}), do: {:error, :upstream_not_found}
  defp status_error(%{status: 416}), do: {:error, :invalid_range}
  defp status_error(_response), do: {:error, :upstream_unavailable}

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
  # whenever extraction failed. In production it fired because the page offered
  # no source the resolver could use: one offered host answered 403 from this
  # server, and another produced no manifest we could fetch independently
  # (measured with service workers blocked, so a worker-served URL is not ruled
  # out). None of that says the title has no source. It is separated
  # here only so the case is countable and can carry its own backoff —
  # everything below stays retryable, because treating an extraction failure
  # as a dead title would take working content out of the catalogue.
  #
  # `unsupported_page` is the opposite kind of signal: the resolver's adapter
  # no longer recognises the upstream page, so every title fails the same way
  # until the adapter is fixed. That is systemic rather than per-title, and a
  # health monitor keys on `:resolver_outdated` to tell the two apart.
  #
  # `challenge_required` means the upstream answered the resolver's browser
  # with a human challenge. The resolver never solves or evades one, so while
  # the upstream keeps challenging, every title fails; it gets its own atom so
  # the health monitor can count it instead of filing it as transient.
  defp resolution_error(body) do
    case Jason.decode(body) do
      {:ok, %{"error" => %{"code" => "stream_unavailable"}}} -> {:error, :no_source_available}
      {:ok, %{"error" => %{"code" => "unsupported_page"}}} -> {:error, :resolver_outdated}
      {:ok, %{"error" => %{"code" => "challenge_required"}}} -> {:error, :challenge_required}
      _ -> {:error, :stream_resolution_failed}
    end
  end

  defp decode_resolution(body) do
    with {:ok, %{} = result} <- Jason.decode(body),
         {:ok, kind, url} <- media_source(result),
         :ok <- UrlValidator.validate_url(url),
         {:ok, headers} <- safe_headers(Map.get(result, "headers", %{})) do
      {:ok, %{kind: kind, url: url, headers: headers, expires_at: Map.get(result, "expires_at")}}
    else
      _ -> {:error, :stream_resolution_failed}
    end
  end

  # The resolver names the delivery format because the only usable upstream
  # turned from HLS into one progressive MP4 per movie. A resolver still on
  # the previous contract sends no `kind`, only `manifest_url`, and that could
  # only ever be HLS; reading it that way lets Streamix and the resolver be
  # redeployed in either order. An unknown `kind` is refused rather than
  # guessed, because serving MP4 bytes as a playlist (or the reverse) fails
  # later and far less legibly.
  defp media_source(%{"kind" => "mp4", "media_url" => url}) when is_binary(url),
    do: {:ok, :mp4, url}

  defp media_source(%{"kind" => "hls", "media_url" => url}) when is_binary(url),
    do: {:ok, :hls, url}

  defp media_source(%{"manifest_url" => url} = result) when is_binary(url) do
    if Map.get(result, "kind") in [nil, "hls"],
      do: {:ok, :hls, url},
      else: {:error, :unsupported_kind}
  end

  defp media_source(_), do: {:error, :unsupported_kind}

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

  defp base_options do
    Embedplay.config(:http_options, []) ++
      [redirect: false, retry: false, decode_body: false, compressed: false]
  end

  defp request(opts) do
    {max_body, opts} = Keyword.pop!(opts, :max_body)
    opts = Keyword.put(opts, :request_timeout, Keyword.fetch!(opts, :receive_timeout))

    options =
      base_options() ++
        [
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
