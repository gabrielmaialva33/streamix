defmodule Streamix.Accounts.IpTracker do
  @moduledoc """
  Extracts IP address and device info from HTTP requests.
  Delegates forwarding trust and address normalization to the network boundary.
  """

  alias Streamix.Accounts.AccessLog
  alias Streamix.Repo
  alias Streamix.Security.ClientIp

  @doc "Extracts the client IP through the configured trusted proxy chain."
  def get_client_ip(conn), do: ClientIp.from_conn(conn)

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
    case task_launcher().start_child(fn -> log_access(conn, user_id) end) do
      {:ok, _pid} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # Private helpers

  defp get_header(conn, header) do
    case Plug.Conn.get_req_header(conn, header) do
      [value | _] -> value
      [] -> nil
    end
  end

  defp task_launcher do
    Application.get_env(:streamix, :ip_tracker_task_launcher, Streamix.TaskLauncher)
  end

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
    ua
    |> detect_from_signatures([
      {["Windows"], "Windows"},
      {["Mac OS"], "macOS"},
      {["Linux"], "Linux"},
      {["Android"], "Android"},
      {["iPhone", "iPad"], "iOS"},
      {["Tizen"], "Tizen"},
      {["webOS"], "webOS"}
    ])
    |> Kernel.||("Other")
  end

  defp detect_os(_), do: "unknown"

  defp detect_from_signatures(ua, signatures) do
    Enum.find_value(signatures, fn {needles, label} ->
      if String.contains?(ua, needles), do: label
    end)
  end
end
