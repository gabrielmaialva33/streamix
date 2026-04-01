defmodule StreamixWeb.Api.V1.EpgController do
  @moduledoc """
  REST API for Electronic Program Guide data.

  Provides EPG schedules for live TV channels. Follows fetch-on-demand
  strategy — clients request a time window and cache locally.
  """
  use StreamixWeb, :controller

  import Ecto.Query, warn: false

  alias Streamix.Iptv.{Epg, EpgProgram, Providers}
  alias Streamix.Repo

  @max_hours 12

  @doc """
  GET /api/v1/epg/programs
  Returns EPG programs for a time window.

  Query params:
    - channel_ids: comma-separated EPG channel IDs (required)
    - hours: number of hours ahead to fetch (default: 6, max: 12)
  """
  def programs(conn, %{"channel_ids" => channel_ids_str} = params) do
    channel_ids = String.split(channel_ids_str, ",", trim: true)
    hours = parse_int(params["hours"], 6) |> min(@max_hours)
    provider = Providers.get_global()

    if is_nil(provider) do
      json(conn, %{programs: %{}})
    else
      now = DateTime.utc_now()
      until = DateTime.add(now, hours * 3600, :second)

      programs =
        EpgProgram
        |> where([p], p.provider_id == ^provider.id)
        |> where([p], p.epg_channel_id in ^channel_ids)
        |> where([p], p.end_time > ^now and p.start_time < ^until)
        |> order_by([p], asc: p.epg_channel_id, asc: p.start_time)
        |> Repo.all()
        |> Enum.group_by(& &1.epg_channel_id)
        |> Map.new(fn {channel_id, progs} ->
          {channel_id, Enum.map(progs, &serialize_program/1)}
        end)

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
  Returns currently airing programs for given channels.
  Lightweight endpoint for channel cards.
  """
  def now(conn, %{"channel_ids" => channel_ids_str}) do
    channel_ids = String.split(channel_ids_str, ",", trim: true)
    provider = Providers.get_global()

    if is_nil(provider) do
      json(conn, %{now: %{}})
    else
      current = Epg.get_current_programs_batch(provider.id, channel_ids)

      now_map =
        Map.new(current, fn {channel_id, program} ->
          {channel_id, serialize_program(program)}
        end)

      json(conn, %{now: now_map})
    end
  end

  def now(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: %{code: "missing_params", message: "channel_ids is required"}})
  end

  # Serializers

  defp serialize_program(%EpgProgram{} = p) do
    %{
      id: p.id,
      title: p.title,
      description: p.description,
      start_time: p.start_time,
      end_time: p.end_time,
      category: p.category,
      is_now: EpgProgram.now?(p),
      progress: EpgProgram.progress(p)
    }
  end

  # Helpers

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
