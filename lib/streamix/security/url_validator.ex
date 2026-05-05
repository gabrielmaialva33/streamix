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
  - Hostname must not resolve to a private/internal IP
  - Blocks 127.0.0.0/8, 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16,
    169.254.0.0/16, 0.0.0.0/8, ::1, fc00::/7, fe80::/10
  """
  @spec validate_url(String.t()) :: :ok | {:error, :unsafe_url}
  def validate_url(url) when is_binary(url) do
    uri = URI.parse(url)

    with :ok <- validate_scheme(uri.scheme),
         :ok <- validate_host_present(uri.host),
         :ok <- validate_host_not_ip_literal(uri.host) do
      validate_resolved_ip(uri.host)
    end
  end

  def validate_url(_), do: {:error, :unsafe_url}

  defp validate_scheme(scheme) when scheme in ["http", "https"], do: :ok

  defp validate_scheme(_) do
    Logger.warning("SSRF blocked: invalid scheme")
    {:error, :unsafe_url}
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

  defp validate_host_not_ip_literal(host) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, ip} ->
        if private_ip?(ip) do
          Logger.warning("SSRF blocked: private IP literal #{host}")
          {:error, :unsafe_url}
        else
          :ok
        end

      {:error, _} ->
        :ok
    end
  end

  defp validate_resolved_ip(host) do
    case resolve_host(host, :inet) do
      {:ok, ip} ->
        validate_resolved_address(host, ip)

      {:error, _} ->
        validate_ipv6_resolution(host)
    end
  end

  defp validate_ipv6_resolution(host) do
    case resolve_host(host, :inet6) do
      {:ok, ip6} ->
        validate_resolved_address(host, ip6)

      {:error, _} ->
        :ok
    end
  end

  defp validate_resolved_address(host, ip) do
    if private_ip?(ip) do
      Logger.warning("SSRF blocked: #{host} resolves to private IP #{format_ip(ip)}")
      {:error, :unsafe_url}
    else
      :ok
    end
  end

  defp resolve_host(host, family) do
    :inet.getaddr(String.to_charlist(host), family)
  end

  defp private_ip?({0, _, _, _}), do: true
  defp private_ip?({10, _, _, _}), do: true
  defp private_ip?({127, _, _, _}), do: true
  defp private_ip?({169, 254, _, _}), do: true
  defp private_ip?({172, b, _, _}) when b >= 16 and b <= 31, do: true
  defp private_ip?({192, 168, _, _}), do: true
  defp private_ip?({255, 255, 255, 255}), do: true
  defp private_ip?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp private_ip?({0, 0, 0, 0, 0, 0, 0, 0}), do: true
  defp private_ip?({w, _, _, _, _, _, _, _}) when w >= 0xFC00 and w <= 0xFDFF, do: true
  defp private_ip?({w, _, _, _, _, _, _, _}) when w >= 0xFE80 and w <= 0xFEBF, do: true

  defp private_ip?({0, 0, 0, 0, 0, 0xFFFF, hi, lo}) do
    a = hi >>> 8
    b = hi &&& 0xFF
    c = lo >>> 8
    d = lo &&& 0xFF
    private_ip?({a, b, c, d})
  end

  defp private_ip?(_), do: false

  defp format_ip({a, b, c, d}), do: "#{a}.#{b}.#{c}.#{d}"
  defp format_ip(ip) when is_tuple(ip), do: :inet.ntoa(ip) |> to_string()
end
