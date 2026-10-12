defmodule Streamix.Torrent.Sources.ScraperHttp do
  @moduledoc """
  HTTP access for the BR HTML torrent scrapers.

  Policy, in one place:

    * **Honest identity.** Every request carries the same
      `Streamix/1.0` User-Agent as the JSON feed and YTS clients. We never
      impersonate a browser.
    * **No circumvention.** A Cloudflare/DDoS-Guard challenge, a 403 or an
      interstitial is reported as `{:blocked, details}`; it is never
      solved, retried with other headers or replayed with cookies.
    * **Politeness.** Requests to one host are spaced by at least the
      site's `min_interval_ms` (1.5 s by default) within a job, and a
      node-wide Hammer bucket keeps concurrent jobs to at most one request
      per host per interval window. Req's automatic retries are disabled;
      HTTP 429 comes back as `{:rate_limited, details}` for the caller to
      back off.

  Errors are `{kind, details}` tuples where `kind` is one of `:blocked`,
  `:rate_limited`, `:not_found`, `:http_error` or `:transport_error` and
  `details` always includes the `:url`.
  """

  alias Streamix.Torrent.Sources.Helpers

  require Logger

  @timeout :timer.seconds(20)
  @max_retry_after_ms :timer.minutes(10)

  # Markers of a bot-management challenge or interstitial page. Matching
  # any of them means "this is not the site's content". Deliberately not
  # "challenge-platform": Cloudflare injects that script path into normal
  # pages too (comandotorrents.to serves it on every 200).
  @challenge_markers [
    "_cf_chl_opt",
    "cf-browser-verification",
    "<title>Just a moment...</title>",
    "Attention Required! | Cloudflare",
    "<title>DDoS-Guard</title>",
    "sucuri_cloudproxy_js"
  ]

  @type error_kind :: :blocked | :rate_limited | :not_found | :http_error | :transport_error
  @type error :: {error_kind(), map()}

  @doc """
  GETs `url` politely and returns the HTML body.

  Options:

    * `:min_interval_ms` — minimum spacing between requests to the host.
  """
  @spec get(String.t(), keyword()) :: {:ok, String.t()} | {:error, error()}
  def get(url, opts \\ []) when is_binary(url) do
    await_turn(url, Keyword.get(opts, :min_interval_ms, 0))

    url
    |> request()
    |> classify(url)
    |> tap(&log_failure/1)
  end

  @doc "Request headers sent to every scraped site. Public for tests."
  @spec headers() :: [{String.t(), String.t()}]
  def headers do
    [
      {"user-agent", Helpers.user_agent()},
      {"accept", "text/html,application/xhtml+xml"},
      {"accept-language", "pt-BR,pt;q=0.9"}
    ]
  end

  @doc """
  Whether a response is a bot-management challenge rather than content.
  Public for tests.
  """
  @spec challenge?(map(), String.t()) :: boolean()
  def challenge?(headers, body) when is_map(headers) and is_binary(body) do
    header_challenge?(headers) or Enum.any?(@challenge_markers, &String.contains?(body, &1))
  end

  defp request(url) do
    options =
      [
        url: url,
        headers: headers(),
        receive_timeout: @timeout,
        retry: false,
        redirect: true,
        max_redirects: 3,
        decode_body: false,
        finch: [name: Streamix.Finch]
      ]
      |> Keyword.merge(Application.get_env(:streamix, :torrent_scraper_request_options, []))

    Req.get(options)
  end

  defp classify({:ok, %Req.Response{status: status, headers: headers, body: body}}, url) do
    body = if is_binary(body), do: body, else: ""
    classify_status(status, headers, body, url)
  end

  defp classify({:error, exception}, url) do
    {:error, {:transport_error, %{url: url, reason: transport_reason(exception)}}}
  end

  defp classify_status(200, headers, body, url) do
    if challenge?(headers, body) do
      {:error, {:blocked, %{url: url, status: 200, reason: :challenge}}}
    else
      {:ok, body}
    end
  end

  defp classify_status(429, headers, _body, url) do
    {:error, {:rate_limited, %{url: url, status: 429, retry_after_ms: retry_after_ms(headers)}}}
  end

  defp classify_status(status, headers, body, url) when status in [401, 403, 503] do
    cond do
      challenge?(headers, body) ->
        {:error, {:blocked, %{url: url, status: status, reason: :challenge}}}

      status == 503 ->
        {:error, {:http_error, %{url: url, status: status}}}

      true ->
        {:error, {:blocked, %{url: url, status: status, reason: :forbidden}}}
    end
  end

  defp classify_status(404, _headers, _body, url),
    do: {:error, {:not_found, %{url: url, status: 404}}}

  defp classify_status(status, _headers, _body, url),
    do: {:error, {:http_error, %{url: url, status: status}}}

  defp header_challenge?(headers) do
    header_values(headers, "cf-mitigated") |> Enum.any?(&(String.downcase(&1) == "challenge"))
  end

  defp header_values(headers, name) do
    case Map.get(headers, name) do
      values when is_list(values) -> Enum.filter(values, &is_binary/1)
      value when is_binary(value) -> [value]
      _ -> []
    end
  end

  defp retry_after_ms(headers) do
    with [value | _] <- header_values(headers, "retry-after"),
         {seconds, ""} <- Integer.parse(String.trim(value)) do
      min(max(seconds, 0) * 1_000, @max_retry_after_ms)
    else
      _ -> nil
    end
  end

  defp transport_reason(%{reason: reason}), do: reason
  defp transport_reason(exception) when is_exception(exception), do: Exception.message(exception)
  defp transport_reason(other), do: other

  defp log_failure({:ok, _body}), do: :ok

  defp log_failure({:error, {kind, details}}) do
    Logger.warning(
      "[Torrent.HtmlScraper] #{details.url} -> #{kind}" <>
        if(details[:status], do: " (HTTP #{details.status})", else: "") <>
        if(details[:reason], do: " #{inspect(details.reason)}", else: "")
    )
  end

  # Pacing. Within a job (one process) consecutive requests to a host are
  # at least `interval_ms` apart. Across jobs the Hammer bucket admits one
  # request per host per window; a denied caller sleeps until the window
  # rolls over.
  #
  # Intentional Process.sleep: scraping runs inside a dedicated Oban job
  # process, the same trade-off documented in `Streamix.Torrent.Sync`.
  defp await_turn(_url, interval_ms) when interval_ms <= 0, do: :ok

  defp await_turn(url, interval_ms) do
    host = url |> URI.parse() |> Map.get(:host) |> to_string() |> String.downcase()
    key = {__MODULE__, :last_request_at, host}

    case Process.get(key) do
      last when is_integer(last) ->
        wait = last + interval_ms - System.monotonic_time(:millisecond)
        if wait > 0, do: Process.sleep(wait)

      _ ->
        :ok
    end

    await_bucket("torrent_scraper:" <> host, interval_ms, 0)
    Process.put(key, System.monotonic_time(:millisecond))
    :ok
  end

  # Gives up waiting after ~a minute of contention rather than wedging the
  # job; the in-process spacing above still holds.
  defp await_bucket(_bucket, _interval_ms, waited_ms) when waited_ms >= 60_000, do: :ok

  defp await_bucket(bucket, interval_ms, waited_ms) do
    case Streamix.RateLimit.hit(bucket, interval_ms, 1) do
      {:allow, _count} ->
        :ok

      {:deny, retry_in_ms} ->
        wait = max(retry_in_ms, 1)
        Process.sleep(wait)
        await_bucket(bucket, interval_ms, waited_ms + wait)
    end
  end
end
