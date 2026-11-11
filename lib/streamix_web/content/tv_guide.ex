defmodule StreamixWeb.Content.TvGuide do
  @moduledoc """
  Read model for the authenticated TV guide.

  The guide keeps provider visibility in the IPTV context, batches program
  windows per provider, and returns presentation-neutral rows for LiveView.
  Only channels with a program in the window are listed: a channel without a
  guide has nothing to show here. Times are Brasília wall-clock
  (`StreamixWeb.Content.LocalTime`).
  """

  alias StreamixWeb.Content.LocalTime

  # Enough for every guided channel a user sees; the page shows them a page
  # at a time.
  @max_channels 1_500
  @window_hours 3
  @tick_minutes 30

  @type row :: %{
          channel: map(),
          programs: [map()],
          current_program: map() | nil,
          next_program: map() | nil,
          provider_name: String.t()
        }

  @doc "Loads visible channels and their programs for one bounded window."
  @spec load(map(), keyword()) :: %{
          rows: [row()],
          categories: [String.t()],
          providers: [map()],
          starts_at: DateTime.t(),
          ends_at: DateTime.t()
        }
  def load(user, opts \\ []) do
    starts_at = Keyword.get_lazy(opts, :starts_at, &default_start/0)
    ends_at = Keyword.get(opts, :ends_at, DateTime.add(starts_at, @window_hours, :hour))
    provider_id = Keyword.get(opts, :provider_id)
    search = Keyword.get(opts, :search, "")

    providers =
      user.id
      |> Streamix.Providers.list_visible_providers()
      |> Enum.filter(&(&1.provider_type == :xtream and &1.is_active))

    provider_names = Map.new(providers, &{&1.id, &1.name})

    channel_opts =
      [
        limit: Keyword.get(opts, :limit, @max_channels),
        search: search,
        show_adult: user.show_adult_content,
        airing_between: {starts_at, ends_at}
      ]
      |> maybe_put(:provider_id, provider_id)

    rows =
      user.id
      |> Streamix.Catalog.list_visible_live_channels(channel_opts)
      |> rows_with_programs(provider_names, starts_at, ends_at)

    %{
      rows: rows,
      categories: program_categories(rows),
      providers: providers,
      starts_at: starts_at,
      ends_at: ends_at
    }
  end

  @doc "Applies UI-only category and favorites filters without new DB work."
  @spec filter([row()], String.t(), boolean(), MapSet.t()) :: [row()]
  def filter(rows, category, favorites_only?, favorite_ids) do
    Enum.filter(rows, fn row ->
      category_matches?(row, category) and
        (not favorites_only? or MapSet.member?(favorite_ids, row.channel.id))
    end)
  end

  @doc "Returns the program currently overlapping now."
  def current_program(programs, now \\ DateTime.utc_now()) do
    Enum.find(programs, fn program ->
      DateTime.compare(program.start_time, now) in [:lt, :eq] and
        DateTime.compare(program.end_time, now) == :gt
    end)
  end

  @doc "Returns the next program starting after now."
  def next_program(programs, now \\ DateTime.utc_now()) do
    programs
    |> Enum.filter(&(DateTime.compare(&1.start_time, now) == :gt))
    |> Enum.sort_by(&DateTime.to_unix(&1.start_time, :microsecond))
    |> List.first()
  end

  @doc """
  Guide order: favorites first, then channels with a real schedule in the
  window (more than one program, or one that does not fill it, unlike a
  provider's all-day "Programação Esportiva" placeholder), then by name.
  """
  @spec rank([row()], MapSet.t(), DateTime.t(), DateTime.t()) :: [row()]
  def rank(rows, favorite_ids, starts_at, ends_at) do
    Enum.sort_by(rows, fn row ->
      {
        if(MapSet.member?(favorite_ids, row.channel.id), do: 0, else: 1),
        if(scheduled?(row.programs, starts_at, ends_at), do: 0, else: 1),
        String.downcase(row.channel.name || "")
      }
    end)
  end

  defp scheduled?([_, _ | _], _starts_at, _ends_at), do: true

  defp scheduled?([program], starts_at, ends_at) do
    DateTime.compare(program.start_time, starts_at) == :gt or
      DateTime.compare(program.end_time, ends_at) == :lt
  end

  defp scheduled?([], _starts_at, _ends_at), do: false

  @doc "Where a program sits relative to `now`: `:past`, `:current` or `:upcoming`."
  @spec program_state(map(), DateTime.t()) :: :past | :current | :upcoming
  def program_state(program, now) do
    cond do
      DateTime.compare(program.end_time, now) != :gt -> :past
      DateTime.compare(program.start_time, now) == :gt -> :upcoming
      true -> :current
    end
  end

  @doc "The window a guide opens on: from the half hour before `now`."
  @spec default_start(DateTime.t()) :: DateTime.t()
  def default_start(now \\ DateTime.utc_now()), do: LocalTime.floor_half_hour(now)

  @doc "The end of a window starting at `starts_at`."
  @spec window_end(DateTime.t()) :: DateTime.t()
  def window_end(starts_at), do: DateTime.add(starts_at, @window_hours, :hour)

  @doc "The time ruler: each half hour in the window with its position in percent."
  @spec ticks(DateTime.t(), DateTime.t()) :: [{DateTime.t(), float()}]
  def ticks(starts_at, ends_at) do
    first = LocalTime.floor_half_hour(starts_at)

    first =
      if DateTime.compare(first, starts_at) == :lt,
        do: DateTime.add(first, @tick_minutes, :minute),
        else: first

    span = max(DateTime.diff(ends_at, starts_at), 1)

    first
    |> Stream.iterate(&DateTime.add(&1, @tick_minutes, :minute))
    |> Enum.take_while(&(DateTime.compare(&1, ends_at) == :lt))
    |> Enum.map(&{&1, DateTime.diff(&1, starts_at) * 100 / span})
  end

  @doc "Formats one instant as Brasília wall-clock time."
  def format_time(nil), do: ""
  def format_time(%DateTime{} = datetime), do: LocalTime.clock(datetime)

  @doc "The selected window: \"Hoje, 13:30–16:30\"."
  def window_label(starts_at, ends_at, now \\ DateTime.utc_now()) do
    "#{LocalTime.day_label(starts_at, now)}, #{format_time(starts_at)}–#{format_time(ends_at)}"
  end

  defp rows_with_programs(channels, provider_names, starts_at, ends_at) do
    programs_by_provider =
      channels
      |> Enum.group_by(& &1.provider_id)
      |> Map.new(fn {provider_id, provider_channels} ->
        channel_ids = Enum.map(provider_channels, & &1.id)

        {provider_id,
         Streamix.Guide.programs_window_for_channels(provider_id, channel_ids, starts_at, ends_at)}
      end)

    now = DateTime.utc_now()

    Enum.map(channels, fn channel ->
      programs =
        programs_by_provider
        |> Map.get(channel.provider_id, %{})
        |> Map.get(to_string(channel.id), [])
        |> drop_umbrellas()

      %{
        channel: channel,
        programs: programs,
        current_program: current_program(programs, now),
        next_program: next_program(programs, now),
        provider_name: Map.get(provider_names, channel.provider_id, "Provedor")
      }
    end)
  end

  # Some guides carry a day-long entry ("MasterChef 22:30–22:30") on top of
  # the real schedule. A program that wholly spans another one of the same
  # channel is such an umbrella and is left out, so one program is on air.
  defp drop_umbrellas(programs) do
    Enum.reject(programs, fn program ->
      Enum.any?(programs, fn other ->
        other.id != program.id and
          DateTime.compare(program.start_time, other.start_time) != :gt and
          DateTime.compare(program.end_time, other.end_time) != :lt and
          DateTime.diff(program.end_time, program.start_time) >
            DateTime.diff(other.end_time, other.start_time)
      end)
    end)
  end

  defp program_categories(rows) do
    rows
    |> Enum.flat_map(& &1.programs)
    |> Enum.map(& &1.category)
    |> Enum.filter(&(is_binary(&1) and String.trim(&1) != ""))
    |> Enum.map(&String.trim/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp category_matches?(_row, category) when category in [nil, "", "all"], do: true

  defp category_matches?(row, category) do
    normalized = String.downcase(category)

    Enum.any?(row.programs, fn program ->
      program.category
      |> to_string()
      |> String.downcase()
      |> String.contains?(normalized)
    end)
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
