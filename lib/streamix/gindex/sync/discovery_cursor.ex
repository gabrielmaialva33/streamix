defmodule Streamix.Gindex.Sync.DiscoveryCursor do
  @moduledoc false

  @strategy "discovery_first_v1"

  @type phase :: :discover | :refresh
  @type t :: %{
          phase: phase(),
          window: String.t(),
          discovery: map() | nil,
          refresh: map() | nil
        }

  @spec load(map() | nil, Date.t() | String.t()) :: t()
  def load(checkpoint, window) do
    window = window_string(window)

    case checkpoint do
      %{"strategy" => @strategy} = cursor -> load_current(cursor, window)
      %{strategy: @strategy} = cursor -> load_current(cursor, window)
      cursor when is_map(cursor) -> new(window, non_empty(cursor))
      _cursor -> new(window, nil)
    end
  end

  @spec phase(t()) :: phase()
  def phase(cursor), do: cursor.phase

  @spec position(t()) :: map() | nil
  def position(%{phase: :discover} = cursor), do: cursor.discovery
  def position(%{phase: :refresh} = cursor), do: cursor.refresh

  @spec checkpoint(t(), phase(), map() | nil) :: map()
  def checkpoint(cursor, phase, position) when phase in [:discover, :refresh] do
    cursor
    |> Map.put(:phase, phase)
    |> Map.put(phase, non_empty(position))
    |> serialize()
  end

  @spec begin_refresh(t()) :: {t(), map()}
  def begin_refresh(cursor) do
    cursor = %{cursor | phase: :refresh, discovery: nil}
    {cursor, serialize(cursor)}
  end

  defp load_current(cursor, window) do
    refresh = cursor |> value("refresh") |> non_empty()

    if value(cursor, "discovery_window") == window do
      %{
        phase: parse_phase(value(cursor, "phase")),
        window: window,
        discovery: cursor |> value("discovery") |> non_empty(),
        refresh: refresh
      }
    else
      new(window, refresh)
    end
  end

  defp new(window, refresh) do
    %{phase: :discover, window: window, discovery: nil, refresh: refresh}
  end

  defp serialize(cursor) do
    %{
      "strategy" => @strategy,
      "phase" => Atom.to_string(cursor.phase),
      "discovery_window" => cursor.window,
      "discovery" => cursor.discovery || %{},
      "refresh" => cursor.refresh || %{}
    }
  end

  defp parse_phase("refresh"), do: :refresh
  defp parse_phase(:refresh), do: :refresh
  defp parse_phase(_phase), do: :discover

  defp value(map, key), do: Map.get(map, key) || Map.get(map, String.to_existing_atom(key))

  defp non_empty(map) when is_map(map) and map_size(map) > 0, do: map
  defp non_empty(_map), do: nil

  defp window_string(%Date{} = date), do: Date.to_iso8601(date)
  defp window_string(window) when is_binary(window), do: window
end
