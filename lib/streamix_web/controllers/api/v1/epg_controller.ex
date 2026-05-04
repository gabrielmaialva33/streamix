defmodule StreamixWeb.Api.V1.EpgController do
  @moduledoc """
  REST API for Electronic Program Guide data.

  Endpoints accept `channel_ids` as a comma-separated list of `LiveChannel.id`
  values (the same IDs returned by `GET /catalog/channels`).

  Responses are keyed by those same `LiveChannel.id`s (as JSON strings),
  with `null` for channels that have no current program / no matching EPG
  data. This keeps the contract stable for TV / mobile clients that pass
  in their own channel-card IDs.

  Times are ISO 8601 UTC. `progress` is a float in `[0.0, 1.0]`.
  """
  use StreamixWeb, :controller

  alias Streamix.Iptv.{Epg, EpgProgram, Providers}

  @max_hours 12

  @doc """
  GET /api/v1/epg/programs
  Returns EPG programs for a time window for each channel.

  Query params:
    - channel_ids: comma-separated LiveChannel IDs (required)
    - hours: number of hours ahead to fetch (default: 6, max: 12)

  Response shape:

      {
        "programs": {
          "1849": [{"title": "...", "description": "...",
                    "start": "2026-04-14T20:00:00Z",
                    "end":   "2026-04-14T20:30:00Z",
                    "category": "News"}, ...],
          "1853": []
        },
        "fetched_until": "2026-04-15T02:00:00Z"
      }
  """
  def programs(conn, %{"channel_ids" => channel_ids_str} = params) do
    channel_ids = parse_channel_ids(channel_ids_str)
    hours = params["hours"] |> parse_int(6) |> min(@max_hours)
    provider = Providers.get_global()

    if is_nil(provider) or channel_ids == [] do
      json(conn, %{programs: empty_list_keyed(channel_ids), fetched_until: nil})
    else
      now = DateTime.utc_now()
      until = DateTime.add(now, hours * 3600, :second)

      programs =
        provider.id
        |> Epg.programs_window_for_channels(channel_ids, now, until)
        |> serialize_programs_window()

      json(conn, %{programs: programs, fetched_until: until})
    end
  end

  def programs(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: %{code: "missing_params", message: "channel_ids is required"}})
  end

  @doc """
  GET /api/v1/epg/now
  Returns the currently airing program for each channel.

  Query params:
    - channel_ids: comma-separated LiveChannel IDs (required)

  Response shape:

      {
        "now": {
          "1849": {"title": "...", "description": "...",
                   "start": "...", "end": "...", "progress": 0.45},
          "1853": null
        }
      }
  """
  def now(conn, %{"channel_ids" => channel_ids_str}) do
    channel_ids = parse_channel_ids(channel_ids_str)
    provider = Providers.get_global()

    if is_nil(provider) or channel_ids == [] do
      json(conn, %{now: empty_keyed(channel_ids)})
    else
      now =
        provider.id
        |> Epg.current_programs_for_channels(channel_ids)
        |> serialize_current_programs()

      json(conn, %{now: now})
    end
  end

  def now(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: %{code: "missing_params", message: "channel_ids is required"}})
  end

  # =============================================================================
  # Serializers
  # =============================================================================

  defp serialize_programs_window(programs_by_channel) do
    Map.new(programs_by_channel, fn {channel_id, programs} ->
      {channel_id, Enum.map(programs, &serialize_program/1)}
    end)
  end

  defp serialize_current_programs(programs_by_channel) do
    Map.new(programs_by_channel, fn
      {channel_id, nil} -> {channel_id, nil}
      {channel_id, program} -> {channel_id, serialize_current_program(program)}
    end)
  end

  defp serialize_program(%EpgProgram{} = p) do
    %{
      id: p.id,
      title: p.title,
      description: p.description,
      start: p.start_time,
      end: p.end_time,
      category: p.category
    }
  end

  defp serialize_current_program(%EpgProgram{} = p) do
    %{
      title: p.title,
      description: p.description,
      start: p.start_time,
      end: p.end_time,
      category: p.category,
      progress: progress_fraction(p)
    }
  end

  # Progress as float in [0.0, 1.0]; clamped for safety.
  defp progress_fraction(%EpgProgram{start_time: s, end_time: e}) do
    total = DateTime.diff(e, s, :second)

    if total > 0 do
      elapsed = DateTime.diff(DateTime.utc_now(), s, :second)

      (elapsed / total)
      |> max(0.0)
      |> min(1.0)
      |> Float.round(3)
    else
      0.0
    end
  end

  # =============================================================================
  # Helpers
  # =============================================================================

  defp parse_channel_ids(str) when is_binary(str) do
    str
    |> String.split(",", trim: true)
    |> Enum.flat_map(fn raw ->
      case raw |> String.trim() |> Integer.parse() do
        {int, _} when int > 0 -> [int]
        _ -> []
      end
    end)
    |> Enum.uniq()
  end

  defp parse_channel_ids(_), do: []

  defp empty_keyed(ids), do: Map.new(ids, fn id -> {to_string(id), nil} end)
  defp empty_list_keyed(ids), do: Map.new(ids, fn id -> {to_string(id), []} end)

  defp parse_int(nil, default), do: default
  defp parse_int(val, _default) when is_integer(val), do: val

  defp parse_int(val, default) when is_binary(val) do
    case Integer.parse(val) do
      {int, _} -> int
      :error -> default
    end
  end

  defp parse_int(_, default), do: default
end
