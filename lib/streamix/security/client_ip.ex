defmodule Streamix.Security.ClientIp do
  @moduledoc "Normalizes client addresses across an explicitly trusted X-Forwarded-For chain."
  import Bitwise

  def from_conn(conn) do
    networks = Application.get_env(:streamix, :trusted_proxy_cidrs, [])
    peer = unmap(conn.remote_ip)

    ip =
      if trusted?(peer, networks) do
        conn
        |> Plug.Conn.get_req_header("x-forwarded-for")
        |> forwarded_chain()
        |> Enum.reverse()
        |> walk(peer, networks)
      else
        peer
      end

    ip |> :inet.ntoa() |> to_string()
  end

  defp walk(chain, peer, networks) do
    Enum.reduce_while(chain, peer, fn address, previous ->
      if trusted?(previous, networks), do: {:cont, address}, else: {:halt, previous}
    end)
  end

  def parse_cidrs!(values) do
    Enum.map(values, fn value ->
      with [address, prefix] <- String.split(value, "/"),
           {:ok, ip} <- parse_ip(address),
           {bits, ""} <- Integer.parse(prefix),
           width = width(ip),
           true <- bits >= 0 and bits <= width do
        {ip, bits}
      else
        _ -> raise ArgumentError, "TRUSTED_PROXY_CIDRS must contain valid IPv4/IPv6 CIDRs"
      end
    end)
  end

  defp forwarded_chain([value]) when byte_size(value) <= 4096 do
    parsed = value |> String.split(",") |> Enum.map(&parse_ip(String.trim(&1)))

    if length(parsed) <= 32 and Enum.all?(parsed, &match?({:ok, _}, &1)),
      do: Enum.map(parsed, &unmap(elem(&1, 1))),
      else: []
  end

  defp forwarded_chain(_headers), do: []
  # A listener bound to `::` sees an IPv4 peer as `::ffff:a.b.c.d` (in production
  # cloudflared reaches the container as ::ffff:172.21.0.1). Compared as IPv6 it
  # would never match an IPv4 CIDR, and every client would collapse into the
  # proxy's address.
  defp unmap({0, 0, 0, 0, 0, 0xFFFF, high, low}),
    do: {high >>> 8, high &&& 0xFF, low >>> 8, low &&& 0xFF}

  defp unmap(ip), do: ip

  defp parse_ip(value), do: value |> to_charlist() |> :inet.parse_strict_address()
  defp width(ip) when tuple_size(ip) == 4, do: 32
  defp width(ip) when tuple_size(ip) == 8, do: 128

  defp trusted?(ip, networks) do
    Enum.any?(networks, fn {network, prefix} ->
      width(ip) == width(network) and
        integer(ip) >>> (width(ip) - prefix) == integer(network) >>> (width(ip) - prefix)
    end)
  end

  defp integer(ip) do
    bits = if tuple_size(ip) == 4, do: 8, else: 16
    ip |> Tuple.to_list() |> Enum.reduce(0, fn part, value -> value <<< bits ||| part end)
  end
end
