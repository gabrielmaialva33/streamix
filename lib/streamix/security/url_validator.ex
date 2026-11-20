defmodule Streamix.Security.UrlValidator do
  @moduledoc """
  Validates URLs to prevent SSRF attacks.

  Blocks requests to internal/private IP ranges and ensures only
  safe schemes (http/https) are used for server-side proxying.
  """

  import Bitwise
  require Logger

  @doc """
  Validates a URL is safe for server-side proxying.

  Returns :ok or {:error, reason}.

  Checks:
  - Only http:// and https:// schemes allowed
  - Embedded credentials are rejected
  - Hostname must not resolve to a private/internal IP
  - Blocks 127.0.0.0/8, 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16,
    169.254.0.0/16, 100.64.0.0/10, IPv4 multicast/reserved space,
    ::1, fc00::/7, fe80::/10, and IPv6 multicast
  """
  @spec validate_url(String.t(), keyword()) :: :ok | {:error, :unsafe_url}
  def validate_url(url, opts \\ [])

  def validate_url(url, opts) when is_binary(url) do
    allow_private_network? = Keyword.get(opts, :allow_private_network, false)

    with {:ok, uri} <- parse_uri(url),
         :ok <- validate_scheme(uri.scheme),
         :ok <- validate_host_present(uri.host),
         :ok <- validate_userinfo(uri.userinfo) do
      validate_network_target(uri.host, allow_private_network?, opts)
    end
  end

  def validate_url(_, _opts), do: {:error, :unsafe_url}

  defp validate_network_target(_host, true, _opts), do: :ok

  defp validate_network_target(host, false, opts) do
    with :ok <- validate_host_not_ip_literal(host) do
      validate_resolved_ip(host, opts)
    end
  end

  defp validate_scheme(scheme) when scheme in ["http", "https"], do: :ok

  defp validate_scheme(_) do
    Logger.warning("SSRF blocked: invalid scheme")
    {:error, :unsafe_url}
  end

  defp parse_uri(url) do
    case URI.new(url) do
      {:ok, uri} ->
        {:ok, uri}

      {:error, _reason} ->
        Logger.warning("SSRF blocked: malformed URL")
        {:error, :unsafe_url}
    end
  end

  defp validate_host_present(nil) do
    Logger.warning("SSRF blocked: missing host")
    {:error, :unsafe_url}
  end

  defp validate_host_present("") do
    Logger.warning("SSRF blocked: empty host")
    {:error, :unsafe_url}
  end

  defp validate_host_present(_), do: :ok

  defp validate_userinfo(nil), do: :ok

  defp validate_userinfo(_userinfo) do
    Logger.warning("SSRF blocked: URL contains embedded credentials")
    {:error, :unsafe_url}
  end

  defp validate_host_not_ip_literal(host) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, ip} ->
        if private_ip?(ip) do
          Logger.warning("SSRF blocked: private IP literal", host: host)
          {:error, :unsafe_url}
        else
          :ok
        end

      {:error, _} ->
        :ok
    end
  end

  defp validate_resolved_ip(host, opts) do
    addresses = resolve_all_addresses(host, opts)

    cond do
      addresses == [] ->
        Logger.warning("SSRF blocked: hostname could not be resolved", host: host)
        {:error, :unsafe_url}

      _unsafe_address = Enum.find(addresses, &private_ip?/1) ->
        Logger.warning("SSRF blocked: hostname resolves to private IP", host: host)
        {:error, :unsafe_url}

      true ->
        :ok
    end
  end

  @l1_cache :streamix_l1_cache
  @negative_ttl :timer.minutes(1)

  # A dead domain previously cost two sequential `:inet.getaddrs` calls
  # (:inet then :inet6), each bounded only by the resolver's own timeouts —
  # ~23 s measured on a SERVFAIL host, paid on every attempt. Families now
  # resolve concurrently with a bounded timeout, and "could not be
  # resolved" is negative-cached per host for 60 s so repeat
  # attempts are cheap. Positive results are never cached: DNS is allowed
  # to heal, and a resolved-private verdict is never memoised as safe.
  defp resolve_all_addresses(host, opts) do
    if negatively_cached?(host) do
      []
    else
      addresses = do_resolve(host, opts)
      if addresses == [], do: cache_unresolvable(host)
      addresses
    end
  end

  defp do_resolve(host, opts) do
    resolver = Keyword.get(opts, :resolver, &default_resolver/3)
    timeout = resolve_timeout_ms()
    host_chars = String.to_charlist(host)

    [:inet, :inet6]
    |> Task.async_stream(
      fn family -> resolver.(host_chars, family, timeout) end,
      max_concurrency: 2,
      timeout: timeout + 500,
      on_timeout: :kill_task
    )
    |> Enum.flat_map(fn
      {:ok, {:ok, addresses}} -> addresses
      _ -> []
    end)
    |> Enum.uniq()
  end

  defp default_resolver(host, family, timeout), do: :inet.getaddrs(host, family, timeout)

  defp resolve_timeout_ms do
    Application.get_env(:streamix, :url_validator_dns_timeout_ms, 2_000)
  end

  defp negatively_cached?(host) do
    ConCache.get(@l1_cache, {:dns_unresolvable, host}) == true
  rescue
    _ -> false
  end

  defp cache_unresolvable(host) do
    ConCache.put(@l1_cache, {:dns_unresolvable, host}, %ConCache.Item{
      value: true,
      ttl: @negative_ttl
    })

    :ok
  rescue
    _ -> :ok
  end

  defp private_ip?({0, _, _, _}), do: true
  defp private_ip?({10, _, _, _}), do: true
  defp private_ip?({127, _, _, _}), do: true
  defp private_ip?({169, 254, _, _}), do: true
  defp private_ip?({172, b, _, _}) when b >= 16 and b <= 31, do: true
  defp private_ip?({192, 168, _, _}), do: true
  defp private_ip?({100, b, _, _}) when b >= 64 and b <= 127, do: true
  defp private_ip?({a, _, _, _}) when a >= 224, do: true
  defp private_ip?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp private_ip?({0, 0, 0, 0, 0, 0, 0, 0}), do: true
  defp private_ip?({w, _, _, _, _, _, _, _}) when w >= 0xFC00 and w <= 0xFDFF, do: true
  defp private_ip?({w, _, _, _, _, _, _, _}) when w >= 0xFE80 and w <= 0xFEBF, do: true
  defp private_ip?({w, _, _, _, _, _, _, _}) when w >= 0xFF00 and w <= 0xFFFF, do: true

  defp private_ip?({0, 0, 0, 0, 0, 0xFFFF, hi, lo}) do
    a = hi >>> 8
    b = hi &&& 0xFF
    c = lo >>> 8
    d = lo &&& 0xFF
    private_ip?({a, b, c, d})
  end

  defp private_ip?(_), do: false
end
