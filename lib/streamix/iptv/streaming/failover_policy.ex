defmodule Streamix.Iptv.Streaming.FailoverPolicy do
  @moduledoc """
  Decides when an upstream URL or status warrants rotating to the next
  alternate host configured for the same provider.

  The rotation itself happens in `VodProxy` — this module owns just the
  predicates so the rules stay in one place and stay testable in isolation.

  ## Triggers

    * **Redirect-pattern match** — the final URL after `RedirectResolver`
      walks the chain matches one of the regexes in
      `:failover_redirect_patterns` (default: `service-abuse`,
      `account-suspended`). Tuliprox-style landing pages that pretend to
      be a stream but actually serve an HTML error.

    * **Terminal upstream status** — 401, 403 (creds rejected), 451
      (geo-block), 429 / 509 (quota). 4xx for "this stream", 5xx for
      "this server".

  Status codes already classified as transient by VodProxy's retry loop
  (5xx + Mint transport errors + idle timeout) only rotate after the
  same-URL retry budget is exhausted, so we don't hop hosts on a transient
  blip.
  """

  @default_patterns [~r/service[-_]abuse/i, ~r/account[-_]suspended/i]

  @doc """
  Returns the configured regex list. Reads at call time so runtime
  overrides take effect without recompile.
  """
  @spec patterns() :: [Regex.t()]
  def patterns do
    Application.get_env(:streamix, :failover_redirect_patterns, @default_patterns)
  end

  @doc """
  True when `url` matches any failover pattern. Empty/nil URLs are false.
  """
  @spec failover_url?(String.t() | nil) :: boolean()
  def failover_url?(url) when is_binary(url) and url != "" do
    Enum.any?(patterns(), &Regex.match?(&1, url))
  end

  def failover_url?(_), do: false

  @doc """
  True when an upstream HTTP status should trigger host rotation
  (creds-rejected / geo-blocked / rate-limited).
  """
  @spec failover_status?(non_neg_integer()) :: boolean()
  def failover_status?(status)
      when status in [401, 403, 429, 451, 509],
      do: true

  def failover_status?(_), do: false

  @doc """
  Substitutes the host of `url` with `host`. Path, query, scheme and
  port are preserved. Returns `:error` when `url` cannot be parsed.
  """
  @spec swap_host(String.t(), String.t()) :: {:ok, String.t()} | :error
  def swap_host(url, host) when is_binary(url) and is_binary(host) do
    case URI.parse(url) do
      %URI{scheme: scheme} when scheme in ["http", "https"] ->
        case URI.parse(host) do
          %URI{host: nil, path: nil} ->
            :error

          parsed ->
            new_uri =
              URI.parse(url)
              |> Map.put(:host, parsed.host || host)
              |> Map.put(:port, parsed.port || URI.parse(url).port)
              |> maybe_swap_scheme(parsed.scheme)

            {:ok, URI.to_string(new_uri)}
        end

      _ ->
        :error
    end
  end

  def swap_host(_, _), do: :error

  defp maybe_swap_scheme(uri, nil), do: uri
  defp maybe_swap_scheme(uri, scheme), do: %{uri | scheme: scheme}

  @doc """
  Builds a failover-aware URL chain by swapping the host of `original_url`
  through each entry in `url_chain` (excluding the original host).

  Returns `[original_url | rotated]`. Order matches `url_chain` so the
  caller can iterate it linearly until one succeeds.
  """
  @spec build_url_chain(String.t(), [String.t()]) :: [String.t()]
  def build_url_chain(original_url, []) when is_binary(original_url), do: [original_url]

  def build_url_chain(original_url, url_chain) when is_binary(original_url) do
    original_host = URI.parse(original_url).host

    rotated =
      url_chain
      |> Enum.reject(fn alt -> URI.parse(alt).host == original_host end)
      |> Enum.flat_map(fn alt ->
        case swap_host(original_url, alt) do
          {:ok, swapped} -> [swapped]
          :error -> []
        end
      end)

    [original_url | rotated]
  end
end
