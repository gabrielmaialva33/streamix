defmodule Streamix.Iptv.Streaming.UpstreamPump do
  @moduledoc """
  Pumps `Finch.stream/5` events into the calling process via mailbox,
  enforcing a byte-window so a slow client cannot bloat the BEAM mailbox
  while we keep an upstream socket open.

  ## Why a separate process

  `Finch.stream/5` runs the user callback inline on the request process.
  When the client TCP buffer fills up, `Plug.Conn.chunk/2` blocks, the
  callback blocks, and Finch stops draining the upstream socket. That is
  *natural* backpressure — but it couples upstream pace to client pace
  packet-by-packet. A microburst (GC pause on the client, transient
  congestion) can stall the upstream and trigger `receive_timeout`.

  This pump decouples them: a Task drains Finch as fast as possible,
  forwards events through the consumer's mailbox, and pauses only when
  bytes-in-flight crosses `cap_bytes` — giving us a configurable burst
  buffer that smooths jitter without unbounded memory.

  ## Protocol

  The consumer receives messages tagged with the pump task pid:

      {pump_pid, {:status, status}}
      {pump_pid, {:headers, headers}}
      {pump_pid, {:data, bin, size}}
      {pump_pid, {:trailers, trailers}}
      {pump_pid, :done}
      {pump_pid, {:error, reason}}

  After consuming a `:data` chunk the consumer **must** send back
  `{:ack, size}` to the pump so the byte-window advances. Forgetting to
  ack stalls the pump after `cap_bytes` and the call eventually times
  out via the configured idle timeout.
  """

  @default_cap_bytes 5 * 1024 * 1024
  @default_receive_timeout 30_000
  @default_pool_timeout 5_000
  @default_ack_timeout 30_000

  @type opts :: [
          cap_bytes: pos_integer(),
          receive_timeout: pos_integer(),
          pool_timeout: pos_integer(),
          ack_timeout: pos_integer()
        ]

  @doc """
  Starts a pump that drains `req` and forwards events to `target`.

  Returns the underlying `Task` so the caller can await/shutdown it.
  """
  @spec start(Finch.Request.t(), atom(), pid(), opts) :: Task.t()
  def start(req, finch_name, target, opts \\ []) do
    cap = Keyword.get(opts, :cap_bytes, @default_cap_bytes)
    receive_timeout = Keyword.get(opts, :receive_timeout, @default_receive_timeout)
    pool_timeout = Keyword.get(opts, :pool_timeout, @default_pool_timeout)
    ack_timeout = Keyword.get(opts, :ack_timeout, @default_ack_timeout)

    Task.async(fn ->
      do_pump(req, finch_name, target, cap, receive_timeout, pool_timeout, ack_timeout)
    end)
  end

  defp do_pump(req, finch_name, target, cap, recv_to, pool_to, ack_to) do
    pump_pid = self()

    callback = fn event, in_flight ->
      handle_event(event, in_flight, target, pump_pid, cap, ack_to)
    end

    case Finch.stream(req, finch_name, 0, callback,
           receive_timeout: recv_to,
           pool_timeout: pool_to
         ) do
      {:ok, _final_in_flight} ->
        send(target, {pump_pid, :done})

      {:error, reason} ->
        send(target, {pump_pid, {:error, reason}})
    end
  end

  defp handle_event({:status, status}, in_flight, target, pump_pid, _cap, _ack_to) do
    send(target, {pump_pid, {:status, status}})
    in_flight
  end

  defp handle_event({:headers, headers}, in_flight, target, pump_pid, _cap, _ack_to) do
    send(target, {pump_pid, {:headers, headers}})
    in_flight
  end

  defp handle_event({:data, bin}, in_flight, target, pump_pid, cap, ack_to) do
    size = byte_size(bin)
    send(target, {pump_pid, {:data, bin, size}})
    wait_for_window(in_flight + size, cap, ack_to)
  end

  defp handle_event({:trailers, trailers}, in_flight, target, pump_pid, _cap, _ack_to) do
    send(target, {pump_pid, {:trailers, trailers}})
    in_flight
  end

  # Drain any pending acks (non-blocking) before we even consider waiting.
  # Keeps in_flight tight under steady-state when the consumer keeps up.
  defp wait_for_window(in_flight, cap, ack_to) do
    in_flight = drain_acks(in_flight)

    if in_flight <= cap do
      in_flight
    else
      receive do
        {:ack, drained} ->
          wait_for_window(in_flight - drained, cap, ack_to)
      after
        ack_to ->
          # Consumer is gone or wedged. Aborting the Task tears down the
          # Finch request, releasing the upstream socket back to the pool.
          exit({:pump_idle, in_flight, cap})
      end
    end
  end

  defp drain_acks(in_flight) do
    receive do
      {:ack, drained} -> drain_acks(in_flight - drained)
    after
      0 -> in_flight
    end
  end
end
