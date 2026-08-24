defmodule StreamixWeb.TorrentStreamController do
  @moduledoc """
  HTTP proxy in front of the rqbit sidecar's `/torrents/{hash}/stream/{idx}`
  endpoint.

  rqbit URLs are internal — never exposed to browsers — because they
  bypass our `Access.plays_global_content?/2` premium gate and
  carry no auth at all. The flow is:

      browser  →  GET /api/stream/torrent/:info_hash/:file_idx
                  (require_authenticated_user)
        →  TorrentStream lookup by info_hash (404 if absent)
        →  Access.plays_global_content? gate
        →  StreamSession.start_or_join(...) — blocks <= 30s
        →  Req → rqbit, Range copied through
        →  Plug.Conn.chunk back to client (200 / 206)

  The `:status` action is a JSON snapshot of `Client.stats/1`, used by
  the LiveView "buffering swarm 5/30" gating.
  """

  use StreamixWeb, :controller

  require Logger

  alias Plug.Conn

  alias Streamix.Access
  alias Streamix.Torrent
  # Headers we copy from the rqbit response back to the browser.
  @forwardable_response_headers ~w(content-type content-length content-range accept-ranges)

  # Headers we forward verbatim from the browser to rqbit.
  @forwardable_request_headers ~w(range if-range)

  # Idle ceiling for a single rqbit chunk. Once headers are in we
  # accept long bodies, but a stalled response after the chunked send
  # is started is treated as a transport hiccup.
  @upstream_receive_timeout_ms 60_000

  @doc """
  GET /api/stream/torrent/:info_hash[/file_idx]
  """
  def stream(conn, %{"info_hash" => info_hash} = params) do
    file_idx_raw = Map.get(params, "file_idx")

    with {:ok, file_idx} <- parse_file_idx(file_idx_raw),
         %{} = ts <- Torrent.get_stream_by_hash(info_hash),
         user = current_user(conn),
         :ok <- authorize(user, ts),
         {:ok, session} <-
           Torrent.start_or_join(ts.info_hash, ts.magnet_uri, self()) do
      do_stream(conn, ts.info_hash, file_idx || session.file_idx)
    else
      :not_found ->
        send_resp(conn, 404, "torrent not found")

      :unauthorized ->
        send_resp(conn, 403, "forbidden")

      {:error, :bad_file_idx} ->
        send_resp(conn, 400, "invalid file_idx")

      {:error, :timeout} ->
        send_resp(conn, 504, "swarm not ready")

      {:error, reason} ->
        Logger.warning("[TorrentStream] start_or_join failed: #{inspect(reason)}")
        send_resp(conn, 502, "torrent backend unavailable")
    end
  end

  @doc """
  GET /api/stream/torrent/:info_hash/status — JSON snapshot for the
  LiveView buffering UI.
  """
  def status(conn, %{"info_hash" => info_hash}) do
    with %{} = ts <- Torrent.get_stream_by_hash(info_hash),
         user = current_user(conn),
         :ok <- authorize(user, ts),
         result <- Torrent.status(ts.info_hash) do
      respond_with_status(conn, result)
    else
      :not_found ->
        send_resp(conn, 404, "torrent not found")

      :unauthorized ->
        send_resp(conn, 403, "forbidden")
    end
  end

  # ---- Internals ----

  defp do_stream(conn, info_hash, file_idx) do
    upstream_url = Torrent.stream_url(info_hash, file_idx)
    headers = build_request_headers(conn)

    # Use Finch directly: streaming HTTP into Plug.Conn.chunk is what
    # the existing VodProxy does too, and it gives us tight control
    # over Range/status forwarding without fighting Req's :into.
    req = Finch.build(:get, upstream_url, headers)

    acc = %{
      conn: conn,
      status: nil,
      sent_headers?: false
    }

    result =
      Finch.stream_while(req, Streamix.StreamFinch, acc, &on_finch_message/2,
        receive_timeout: @upstream_receive_timeout_ms,
        pool_timeout: 5_000
      )

    case result do
      {:ok, %{conn: conn, sent_headers?: true}} ->
        conn

      {:ok, %{conn: conn, sent_headers?: false, status: status}} when is_integer(status) ->
        send_resp(conn, status, "")

      {:ok, %{conn: conn}} ->
        send_resp(conn, 502, "torrent upstream error")

      {:error, _reason, %{conn: chunked_conn, sent_headers?: true}} ->
        # Headers were already on the wire; let the chunked send drop.
        chunked_conn

      {:error, reason, _acc} ->
        Logger.warning("[TorrentStream] upstream error: #{inspect(reason)}")
        send_resp(conn, 502, "torrent upstream error")
    end
  end

  defp on_finch_message({:status, status}, acc), do: {:cont, %{acc | status: status}}

  defp on_finch_message({:headers, headers}, %{conn: conn, status: status} = acc) do
    status = status || 200

    conn =
      conn
      |> copy_response_headers(headers)
      |> Conn.put_resp_header("cache-control", "no-cache, no-store")
      |> Conn.send_chunked(status)

    {:cont, %{acc | conn: conn, sent_headers?: true}}
  end

  defp on_finch_message({:data, chunk}, %{conn: conn, sent_headers?: true} = acc) do
    case Conn.chunk(conn, chunk) do
      {:ok, conn} -> {:cont, %{acc | conn: conn}}
      {:error, _} -> {:halt, acc}
    end
  end

  defp on_finch_message({:data, _chunk}, acc), do: {:cont, acc}
  defp on_finch_message({:trailers, _}, acc), do: {:cont, acc}
  defp on_finch_message(:done, acc), do: {:cont, acc}
  defp on_finch_message(_, acc), do: {:cont, acc}

  defp copy_response_headers(conn, upstream_headers) do
    Enum.reduce(@forwardable_response_headers, conn, fn name, acc ->
      case List.keyfind(upstream_headers, name, 0) do
        {^name, value} when is_binary(value) ->
          Conn.put_resp_header(acc, name, value)

        {^name, [value | _]} when is_binary(value) ->
          Conn.put_resp_header(acc, name, value)

        _ ->
          acc
      end
    end)
  end

  defp build_request_headers(conn) do
    forwarded =
      Enum.flat_map(@forwardable_request_headers, fn name ->
        case Conn.get_req_header(conn, name) do
          [value | _] -> [{name, value}]
          [] -> []
        end
      end)

    # The stream proxy hits rqbit directly (not via Client.request/3),
    # so it must carry the same shared-secret header the edge expects.
    Torrent.auth_headers() ++ forwarded
  end

  defp parse_file_idx(nil), do: {:ok, nil}

  defp parse_file_idx(raw) when is_binary(raw) do
    case Integer.parse(raw) do
      {n, ""} when n >= 0 -> {:ok, n}
      _ -> {:error, :bad_file_idx}
    end
  end

  defp parse_file_idx(_), do: {:error, :bad_file_idx}

  defp authorize(nil, _ts), do: :unauthorized

  defp authorize(user, _ts) do
    # Torrent content is delivered through the system-wide
    # TorrentProvider. The Access gate handles admin / subscribed /
    # explicit-permission paths — we just supply the provider so it
    # can recognize this as global content.
    case Streamix.Providers.get_torrent_provider() do
      nil ->
        :unauthorized

      provider ->
        if Access.plays_global_content?(user, provider) do
          :ok
        else
          :unauthorized
        end
    end
  end

  defp current_user(conn) do
    case conn.assigns[:current_scope] do
      %{user: user} -> user
      _ -> nil
    end
  end

  defp respond_with_status(conn, {:ok, payload}), do: json(conn, payload)

  defp respond_with_status(conn, {:error, payload}) do
    conn
    |> put_status(:service_unavailable)
    |> json(payload)
  end
end
