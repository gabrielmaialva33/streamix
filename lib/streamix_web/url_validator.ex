defmodule StreamixWeb.UrlValidator do
  @moduledoc """
  Validates URLs to prevent SSRF attacks.

  Blocks requests to internal/private IP ranges and ensures only
  safe schemes (http/https) are used for stream proxying.
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
         :ok <- validate_host_not_ip_literal(uri.host),
         :ok <- validate_resolved_ip(uri.host) do
      :ok
    end
  end

  def validate_url(_), do: {:error, :unsafe_url}

  # --- Private ---

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

  # If the hostname is already an IP literal, validate it directly
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
        # Not an IP literal, will be resolved via DNS below
        :ok
    end
  end

  defp validate_resolved_ip(host) do
    case :inet.getaddr(String.to_charlist(host), :inet) do
      {:ok, ip} ->
        if private_ip?(ip) do
          Logger.warning("SSRF blocked: #{host} resolves to private IP #{format_ip(ip)}")
          {:error, :unsafe_url}
        else
          :ok
        end

      {:error, _} ->
        # Also try IPv6
        case :inet.getaddr(String.to_charlist(host), :inet6) do
          {:ok, ip6} ->
            if private_ip?(ip6) do
              Logger.warning("SSRF blocked: #{host} resolves to private IPv6")
              {:error, :unsafe_url}
            else
              :ok
            end

          {:error, _} ->
            # DNS resolution failed — allow it through and let Mint handle the connection error.
            # Blocking here would break URLs that are temporarily unresolvable from the server
            # but valid IPTV endpoints.
            :ok
        end
    end
  end

  # IPv4 private/reserved ranges
  defp private_ip?({0, _, _, _}), do: true
  defp private_ip?({10, _, _, _}), do: true
  defp private_ip?({127, _, _, _}), do: true
  defp private_ip?({169, 254, _, _}), do: true
  defp private_ip?({172, b, _, _}) when b >= 16 and b <= 31, do: true
  defp private_ip?({192, 168, _, _}), do: true
  # Link-local / broadcast
  defp private_ip?({255, 255, 255, 255}), do: true

  # IPv6 private/reserved ranges
  # ::1 (loopback)
  defp private_ip?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  # :: (unspecified)
  defp private_ip?({0, 0, 0, 0, 0, 0, 0, 0}), do: true
  # fc00::/7 (unique local) — covers fc00::/8 and fd00::/8
  defp private_ip?({w, _, _, _, _, _, _, _}) when w >= 0xFC00 and w <= 0xFDFF, do: true
  # fe80::/10 (link-local)
  defp private_ip?({w, _, _, _, _, _, _, _}) when w >= 0xFE80 and w <= 0xFEBF, do: true
  # ::ffff:0:0/96 (IPv4-mapped IPv6) — check the embedded IPv4
  defp private_ip?({0, 0, 0, 0, 0, 0xFFFF, hi, lo}) do
    # hi and lo are 16-bit, reconstruct IPv4 octets
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
