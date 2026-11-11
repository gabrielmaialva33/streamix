defmodule Streamix.Programming.StationServer do
  @moduledoc """
  One process per on-air station. It knows the station's program and wakes
  exactly when the current item ends, to tell every viewer what plays next
  (`{:station_slot, slug, slot}` on `Streamix.Programming.topic/1`), so a
  thousand viewers need no thousand timers and no polling.

  Asking what plays now is also answered here, from memory; the arithmetic
  is `Streamix.Programming.Schedule`, so a restart loses nothing.
  """

  use GenServer, restart: :transient

  alias Streamix.Programming
  alias Streamix.Programming.Schedule

  @registry Streamix.Programming.Registry

  def start_link(slug) when is_binary(slug),
    do: GenServer.start_link(__MODULE__, slug, name: via(slug))

  def child_spec(slug),
    do: %{id: {__MODULE__, slug}, start: {__MODULE__, :start_link, [slug]}, restart: :transient}

  @doc false
  def via(slug), do: {:via, Registry, {@registry, slug}}

  @doc "The station and what it plays now, or nil when this station has no server."
  @spec now_playing(String.t()) :: {map(), Schedule.slot() | nil} | nil
  def now_playing(slug) do
    case Registry.lookup(@registry, slug) do
      [{pid, _value}] -> GenServer.call(pid, :now_playing)
      [] -> nil
    end
  catch
    :exit, _reason -> nil
  end

  @doc "Re-reads the station (after a new program) and tells viewers."
  @spec reload(String.t()) :: :ok
  def reload(slug), do: GenServer.cast(via(slug), :reload)

  @impl true
  def init(slug), do: {:ok, %{slug: slug, station: nil, timer: nil}, {:continue, :load}}

  @impl true
  def handle_continue(:load, state) do
    case Programming.get_station(state.slug) do
      %{active: true} = station -> {:noreply, schedule(%{state | station: station})}
      _missing_or_off -> {:stop, :normal, state}
    end
  end

  # A reload announces too: viewers of the old program move to the new one.
  def handle_continue(:reload, state) do
    case Programming.get_station(state.slug) do
      %{active: true} = station -> {:noreply, announce(%{state | station: station})}
      _missing_or_off -> {:stop, :normal, state}
    end
  end

  @impl true
  def handle_call(:now_playing, _from, %{station: station} = state),
    do: {:reply, {station, Schedule.at(station, DateTime.utc_now())}, state}

  @impl true
  def handle_cast(:reload, state) do
    if state.timer, do: Process.cancel_timer(state.timer)
    {:noreply, state, {:continue, :reload}}
  end

  @impl true
  def handle_info(:advance, state), do: {:noreply, announce(state)}

  def handle_info(_message, state), do: {:noreply, state}

  defp announce(state) do
    slot = Schedule.at(state.station, DateTime.utc_now())

    Phoenix.PubSub.broadcast(
      Streamix.PubSub,
      Programming.topic(state.slug),
      {:station_slot, state.slug, slot}
    )

    schedule(state, slot)
  end

  defp schedule(state, slot \\ nil) do
    slot = slot || Schedule.at(state.station, DateTime.utc_now())

    timer =
      case slot do
        %{ends_at: ends_at} ->
          wait = max(DateTime.diff(ends_at, DateTime.utc_now(), :millisecond), 1_000)
          Process.send_after(self(), :advance, wait)

        nil ->
          nil
      end

    %{state | timer: timer}
  end
end
