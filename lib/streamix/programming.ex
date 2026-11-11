defmodule Streamix.Programming do
  @moduledoc """
  24h stations built from the catalog: "Terror Anos 80", "Comédia Romântica".

  A station is a discovery query turned into a looping program of movies
  (`Streamix.Programming.ProgramBuilder`). What plays now is arithmetic on
  the clock (`Streamix.Programming.Schedule`), so everyone tuning in lands on
  the same film at the same minute, with no host and no room. Each on-air
  station has a process (`Streamix.Programming.StationServer`) that wakes when
  an item ends and broadcasts the next slot on `topic/1`.
  """

  import Ecto.Query, warn: false

  alias Streamix.Programming.{Lineup, ProgramBuilder, Schedule, Station, StationServer}
  alias Streamix.Repo
  alias Streamix.SafeLog

  require Logger

  @type now_playing :: %{station: Station.t(), slot: Schedule.slot()}

  @doc "Whether station servers start with the application."
  @spec autostart?() :: boolean()
  def autostart?,
    do: :streamix |> Application.get_env(__MODULE__, []) |> Keyword.get(:autostart, false)

  @doc "The PubSub topic a station announces its slots on."
  @spec topic(String.t()) :: String.t()
  def topic(slug), do: "station:" <> slug

  @doc "Subscribes the caller to a station's slot announcements."
  @spec subscribe(String.t()) :: :ok | {:error, term()}
  def subscribe(slug), do: Phoenix.PubSub.subscribe(Streamix.PubSub, topic(slug))

  @doc "Active stations with a program, in display order."
  @spec list_stations() :: [Station.t()]
  def list_stations do
    Repo.all(
      from(s in Station,
        where: s.active and fragment("cardinality(?) > 0", s.program),
        order_by: [asc: s.position, asc: s.id]
      )
    )
  end

  @doc "A station by slug, or nil."
  @spec get_station(String.t()) :: Station.t() | nil
  def get_station(slug) when is_binary(slug), do: Repo.get_by(Station, slug: slug)

  @doc """
  What a station plays now. Answered by its server when on air, otherwise
  computed from the stored program.
  """
  @spec now_playing(String.t()) :: {:ok, now_playing()} | {:error, :not_found | :off_air}
  def now_playing(slug) when is_binary(slug) do
    case StationServer.now_playing(slug) || from_store(slug) do
      {%Station{} = station, %{} = slot} -> {:ok, %{station: station, slot: slot}}
      {%Station{}, nil} -> {:error, :off_air}
      nil -> {:error, :not_found}
    end
  end

  defp from_store(slug) do
    case get_station(slug) do
      %Station{active: true} = station -> {station, Schedule.at(station, DateTime.utc_now())}
      _missing_or_off -> nil
    end
  end

  @doc "Every listed station with what it plays now."
  @spec list_now_playing() :: [now_playing()]
  def list_now_playing do
    Enum.flat_map(list_stations(), fn station ->
      case now_playing(station.slug) do
        {:ok, playing} -> [playing]
        {:error, _reason} -> []
      end
    end)
  end

  @doc "Share of the current item already played, 0.0 to 1.0."
  defdelegate progress(slot), to: Schedule

  @doc """
  Creates the shipped stations (`Streamix.Programming.Lineup`) that are
  missing, refreshes the editorial fields of the rest and deactivates
  stations no longer shipped.
  """
  @spec sync_lineup() :: :ok
  def sync_lineup do
    shipped = Lineup.stations()

    for attrs <- shipped do
      (get_station(attrs.slug) || %Station{})
      |> Station.changeset(Map.put(attrs, :active, true))
      |> Repo.insert_or_update!()
    end

    slugs = Enum.map(shipped, & &1.slug)
    Repo.update_all(from(s in Station, where: s.slug not in ^slugs), set: [active: false])
    :ok
  end

  @doc """
  Builds a fresh program for every active station (only those without one
  with `only_empty: true`), starting it now. A station whose build fails
  keeps its current program. Returns the slugs rebuilt.
  """
  @spec rebuild_programs(keyword()) :: [String.t()]
  def rebuild_programs(opts \\ []) do
    only_empty? = Keyword.get(opts, :only_empty, false)
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)

    from(s in Station, where: s.active, order_by: s.position)
    |> Repo.all()
    |> Enum.filter(&(not only_empty? or &1.program == []))
    |> Enum.flat_map(fn station ->
      case ProgramBuilder.build(station, DateTime.to_date(now)) do
        {:ok, program} ->
          station |> Station.program_changeset(program, now) |> Repo.update!()
          StationServer.reload(station.slug)
          [station.slug]

        {:error, reason} ->
          Logger.warning("[Programming] program not rebuilt",
            content_ref: station.slug,
            reason: SafeLog.redact_inspect(reason)
          )

          []
      end
    end)
  end

  @doc "Starts a server for every listed station that has none."
  @spec ensure_on_air() :: :ok
  def ensure_on_air do
    for station <- list_stations() do
      DynamicSupervisor.start_child(
        Streamix.Programming.StationSupervisor,
        {StationServer, station.slug}
      )
    end

    :ok
  end
end
