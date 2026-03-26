defmodule Streamix.Accounts.IpTracker do
  @moduledoc """
  Extracts IP address and device info from HTTP requests.
  Handles Cloudflare headers for real client IP.
  """

  alias Streamix.Repo
  alias Streamix.Accounts.AccessLog

  @doc """
  Extracts client IP from conn, handling proxies and Cloudflare.
  Priority: CF-Connecting-IP > X-Forwarded-For > X-Real-IP > remote_ip
  """
  def get_client_ip(conn) do
    conn
    |> get_header("cf-connecting-ip")
    |> or_else(fn -> get_forwarded_for(conn) end)
    |> or_else(fn -> get_header(conn, "x-real-ip") end)
    |> or_else(fn -> format_ip(conn.remote_ip) end)
  end

  @doc """
  Extracts all request info for tracking.
  """
  def get_request_info(conn) do
    user_agent = get_header(conn, "user-agent") || ""

    %{
      ip_address: get_client_ip(conn),
      user_agent: user_agent,
      path: conn.request_path,
      method: conn.method,
      device_type: detect_device_type(user_agent),
      browser: detect_browser(user_agent),
      os: detect_os(user_agent),
      country: get_header(conn, "cf-ipcountry"),
      city: get_header(conn, "cf-ipcity")
    }
  end

  @doc """
  Logs an access event to the database.
  """
  def log_access(conn, user_id \\ nil) do
    info = get_request_info(conn)

    %AccessLog{}
    |> AccessLog.changeset(Map.put(info, :user_id, user_id))
    |> Repo.insert()
  end

  @doc """
  Logs access asynchronously (non-blocking).
  """
  def log_access_async(conn, user_id \\ nil) do
    Task.start(fn -> log_access(conn, user_id) end)
    :ok
  end

  # Private helpers

  defp get_header(conn, header) do
    case Plug.Conn.get_req_header(conn, header) do
      [value | _] -> value
      [] -> nil
    end
  end

  defp get_forwarded_for(conn) do
    case get_header(conn, "x-forwarded-for") do
      nil ->
        nil

      value ->
        value
        |> String.split(",")
        |> List.first()
        |> String.trim()
    end
  end

  defp format_ip(ip_tuple) when is_tuple(ip_tuple) do
    ip_tuple
    |> Tuple.to_list()
    |> Enum.join(".")
  end

  defp format_ip(ip), do: to_string(ip)

  defp or_else(nil, func), do: func.()
  defp or_else(value, _func), do: value

  # Device detection from User-Agent

  defp detect_device_type(ua) when is_binary(ua) do
    ua_lower = String.downcase(ua)

    cond do
      String.contains?(ua_lower, [
        "smart-tv",
        "smarttv",
        "tv",
        "webos",
        "tizen",
        "roku",
        "firetv",
        "appletv"
      ]) ->
        "tv"

      String.contains?(ua_lower, ["mobile", "android", "iphone", "ipod", "windows phone"]) ->
        "mobile"

      String.contains?(ua_lower, ["tablet", "ipad"]) ->
        "tablet"

      true ->
        "desktop"
    end
  end

  defp detect_device_type(_), do: "unknown"

  defp detect_browser(ua) when is_binary(ua) do
    cond do
      String.contains?(ua, "Firefox") -> "Firefox"
      String.contains?(ua, "Edg/") -> "Edge"
      String.contains?(ua, "Chrome") -> "Chrome"
      String.contains?(ua, "Safari") -> "Safari"
      String.contains?(ua, "Opera") or String.contains?(ua, "OPR") -> "Opera"
      true -> "Other"
    end
  end

  defp detect_browser(_), do: "unknown"

  defp detect_os(ua) when is_binary(ua) do
    cond do
      String.contains?(ua, "Windows") -> "Windows"
      String.contains?(ua, "Mac OS") -> "macOS"
      String.contains?(ua, "Linux") -> "Linux"
      String.contains?(ua, "Android") -> "Android"
      String.contains?(ua, "iPhone") or String.contains?(ua, "iPad") -> "iOS"
      String.contains?(ua, "Tizen") -> "Tizen"
      String.contains?(ua, "webOS") -> "webOS"
      true -> "Other"
    end
  end

  defp detect_os(_), do: "unknown"
end
