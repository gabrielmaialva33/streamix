defmodule Streamix.Iptv.Streaming.VodProxy.Transfer do
  @moduledoc false

  alias Plug.Conn
  alias Streamix.Iptv.Streaming.UpstreamPump
  alias Streamix.Iptv.Streaming.VodProxy.Headers

  @burst_buffer_bytes 5 * 1_024 * 1_024
  @upstream_idle_timeout_ms 30_000
  @terminal_statuses [400, 401, 403, 404, 405, 410, 416, 451]

  @type result ::
          {:ok, Conn.t(), map()}
          | {:error, :client_closed, Conn.t(), map()}
          | {:error, :before_first_byte, term()}
          | {:error, {:after_chunk, Conn.t(), non_neg_integer()}, term()}
          | {:error, :status_terminal | :status_no_partial, non_neg_integer()}

  @spec stream(Conn.t(), term(), map()) :: result()
  def stream(conn, request, state) do
    accumulator = %{
      conn: conn,
      status: nil,
      sent_headers?: false,
      bytes_sent: state.bytes_sent,
      total_sent: state.bytes_sent,
      attempting_resume?: state.bytes_sent > 0
    }

    pump =
      UpstreamPump.start(request, Streamix.StreamFinch, self(),
        cap_bytes: @burst_buffer_bytes,
        receive_timeout: @upstream_idle_timeout_ms,
        pool_timeout: 5_000
      )

    try do
      consume(pump, accumulator)
    after
      Task.shutdown(pump, :brutal_kill)
    end
  end

  defp consume(pump, accumulator) do
    pump_pid = pump.pid
    pump_ref = pump.ref

    receive do
      {^pump_pid, {:status, status}} ->
        consume(pump, on_status(status, accumulator))

      {^pump_pid, {:headers, headers}} ->
        consume(pump, on_headers(headers, accumulator))

      {^pump_pid, {:data, chunk, size}} ->
        consume(pump, on_data(chunk, size, accumulator, pump_pid))

      {^pump_pid, {:trailers, _trailers}} ->
        consume(pump, accumulator)

      {^pump_pid, :done} ->
        on_done(accumulator)

      {^pump_pid, {:error, reason}} ->
        on_error(reason, accumulator)

      {:DOWN, ^pump_ref, :process, ^pump_pid, reason} ->
        on_error({:pump_down, reason}, accumulator)
    end
  catch
    {:client_closed, %{conn: conn} = accumulator} ->
      {:error, :client_closed, conn, accumulator}

    {:upstream_error, status, %{sent_headers?: false}} ->
      if status in @terminal_statuses do
        {:error, :status_terminal, status}
      else
        {:error, :before_first_byte, {:unexpected_status, status}}
      end

    {:upstream_error, status, %{conn: conn, total_sent: total_sent}} ->
      {:error, {:after_chunk, conn, total_sent}, {:unexpected_status, status}}

    {:no_partial_on_resume, status, _accumulator} ->
      {:error, :status_no_partial, status}
  end

  defp on_status(status, %{attempting_resume?: true} = accumulator)
       when status not in [206, 416] do
    throw({:no_partial_on_resume, status, accumulator})
  end

  defp on_status(status, accumulator) when status in 200..299 do
    %{accumulator | status: status}
  end

  defp on_status(status, accumulator), do: throw({:upstream_error, status, accumulator})

  defp on_headers(
         _headers,
         %{attempting_resume?: true, conn: %Conn{state: :chunked}} = accumulator
       ) do
    %{accumulator | sent_headers?: true}
  end

  defp on_headers(headers, accumulator) do
    conn =
      Headers.send_chunked(
        accumulator.conn,
        accumulator.status || 200,
        headers,
        accumulator.attempting_resume?
      )

    %{accumulator | conn: conn, sent_headers?: true}
  end

  defp on_data(chunk, size, accumulator, pump_pid) do
    case Conn.chunk(accumulator.conn, chunk) do
      {:ok, conn} ->
        send(pump_pid, {:ack, size})

        %{
          accumulator
          | conn: conn,
            total_sent: accumulator.total_sent + size,
            bytes_sent: accumulator.bytes_sent + size
        }

      {:error, :closed} ->
        throw({:client_closed, accumulator})

      {:error, _reason} ->
        throw({:client_closed, accumulator})
    end
  end

  defp on_done(%{sent_headers?: true} = accumulator) do
    {:ok, accumulator.conn, accumulator}
  end

  defp on_done(_accumulator), do: {:error, :before_first_byte, :empty_upstream}

  defp on_error(reason, %{sent_headers?: true, conn: conn, total_sent: total_sent}) do
    {:error, {:after_chunk, conn, total_sent}, reason}
  end

  defp on_error(reason, _accumulator), do: {:error, :before_first_byte, reason}
end
