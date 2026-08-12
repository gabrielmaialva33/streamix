defmodule Streamix.Iptv.Streaming.StreamMultiplexer.Subscribers do
  @moduledoc false

  @max_buffer_bytes 5 * 1_024 * 1_024

  def put(state, pid) do
    case Map.get(state.subscribers, pid) do
      nil ->
        subscriber = %{
          monitor_ref: Process.monitor(pid),
          demand: 0,
          queue: :queue.new(),
          queued_bytes: 0
        }

        {%{state | subscribers: Map.put(state.subscribers, pid, subscriber)}, subscriber}

      subscriber ->
        {state, subscriber}
    end
  end

  def demand(state, pid) do
    update(state, pid, fn subscriber ->
      subscriber
      |> Map.update!(:demand, &min(&1 + 1, 1))
      |> deliver_pending(pid)
    end)
  end

  def remove(state, pid, demonitor? \\ true) do
    case Map.pop(state.subscribers, pid) do
      {nil, _subscribers} ->
        state

      {%{monitor_ref: monitor_ref}, subscribers} ->
        if demonitor?, do: Process.demonitor(monitor_ref, [:flush])
        %{state | subscribers: subscribers}
    end
  end

  def notify_ready(state) do
    backlog = :queue.to_list(state.buffer)

    Enum.each(state.subscribers, fn {pid, _subscriber} ->
      send(pid, {
        :stream_mux,
        self(),
        {:ready, state.response_status || 200, state.response_headers, backlog}
      })
    end)
  end

  def notify_error(state, reason) do
    Enum.each(state.subscribers, fn {pid, _subscriber} ->
      send(pid, {:stream_mux, self(), {:error, reason}})
    end)
  end

  def push_chunk(state, chunk) do
    state = put_ring_buffer(state, chunk)

    subscribers =
      Enum.reduce(state.subscribers, %{}, fn {pid, subscriber}, subscribers ->
        case enqueue(pid, subscriber, chunk, state.subscriber_buffer_bytes) do
          {:keep, subscriber} -> Map.put(subscribers, pid, subscriber)
          :drop -> subscribers
        end
      end)

    %{state | subscribers: subscribers}
    |> maybe_start_idle_timer()
  end

  def enqueue_terminal(state, event) do
    subscribers =
      Enum.reduce(state.subscribers, %{}, fn {pid, subscriber}, subscribers ->
        subscriber = %{subscriber | queue: :queue.in({:terminal, event}, subscriber.queue)}

        case deliver_pending(subscriber, pid) do
          {:keep, subscriber} ->
            Map.put(subscribers, pid, subscriber)

          :drop ->
            Process.demonitor(subscriber.monitor_ref, [:flush])
            subscribers
        end
      end)

    %{state | subscribers: subscribers}
    |> maybe_start_idle_timer()
  end

  def cancel_idle_timer(%{idle_timer: nil} = state), do: state

  def cancel_idle_timer(%{idle_timer: timer} = state) do
    Process.cancel_timer(timer)
    %{state | idle_timer: nil}
  end

  def maybe_start_idle_timer(state) do
    if map_size(state.subscribers) == 0 and is_nil(state.idle_timer) do
      %{state | idle_timer: Process.send_after(self(), :idle_timeout, state.idle_timeout)}
    else
      state
    end
  end

  defp update(state, pid, fun) do
    case Map.fetch(state.subscribers, pid) do
      {:ok, subscriber} ->
        case fun.(subscriber) do
          {:keep, subscriber} ->
            %{state | subscribers: Map.put(state.subscribers, pid, subscriber)}

          :drop ->
            remove(state, pid)
        end

      :error ->
        state
    end
  end

  defp deliver_pending(%{demand: demand} = subscriber, _pid) when demand <= 0 do
    {:keep, subscriber}
  end

  defp deliver_pending(subscriber, pid) do
    case :queue.out(subscriber.queue) do
      {:empty, _queue} ->
        {:keep, subscriber}

      {{:value, {:chunk, chunk, size}}, queue} ->
        send(pid, {:stream_mux, self(), {:chunk, chunk}})

        {:keep,
         %{
           subscriber
           | demand: subscriber.demand - 1,
             queue: queue,
             queued_bytes: subscriber.queued_bytes - size
         }}

      {{:value, {:terminal, event}}, _queue} ->
        send(pid, {:stream_mux, self(), event})
        :drop
    end
  end

  defp enqueue(pid, subscriber, chunk, max_buffer_bytes) do
    size = byte_size(chunk)

    if size > max_buffer_bytes do
      send(pid, {:stream_mux, self(), {:error, :slow_consumer}})
      Process.demonitor(subscriber.monitor_ref, [:flush])
      :drop
    else
      subscriber = discard_stale_chunks(subscriber, size, max_buffer_bytes)

      subscriber = %{
        subscriber
        | queue: :queue.in({:chunk, chunk, size}, subscriber.queue),
          queued_bytes: subscriber.queued_bytes + size
      }

      deliver_pending(subscriber, pid)
    end
  end

  defp discard_stale_chunks(subscriber, incoming_size, max_buffer_bytes)
       when subscriber.queued_bytes + incoming_size > max_buffer_bytes do
    case :queue.out(subscriber.queue) do
      {{:value, {:chunk, _chunk, size}}, queue} ->
        %{subscriber | queue: queue, queued_bytes: subscriber.queued_bytes - size}
        |> discard_stale_chunks(incoming_size, max_buffer_bytes)

      _ ->
        subscriber
    end
  end

  defp discard_stale_chunks(subscriber, _incoming_size, _max_buffer_bytes), do: subscriber

  defp put_ring_buffer(state, chunk) do
    buffer = :queue.in(chunk, state.buffer)
    count = state.buffer_count + 1
    bytes = state.buffer_bytes + byte_size(chunk)

    {buffer, count, bytes} = trim_buffer(buffer, count, bytes, state.buffer_size)

    %{state | buffer: buffer, buffer_count: count, buffer_bytes: bytes}
  end

  defp trim_buffer(buffer, count, bytes, max_count)
       when count > max_count or (count > 1 and bytes > @max_buffer_bytes) do
    {{:value, old_chunk}, buffer} = :queue.out(buffer)
    trim_buffer(buffer, count - 1, bytes - byte_size(old_chunk), max_count)
  end

  defp trim_buffer(buffer, count, bytes, _max_count), do: {buffer, count, bytes}
end
