defmodule StreamixWeb.Content.TvGuide do
  @moduledoc """
  Read model for the authenticated TV guide.

  The guide keeps provider visibility in the IPTV context, batches program
  windows per provider, and returns presentation-neutral rows for LiveView.
  """

  @default_limit 100
  @window_hours 3

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
        limit: Keyword.get(opts, :limit, @default_limit),
        search: search,
        show_adult: user.show_adult_content
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

  @doc "Formats one DateTime in the application guide timezone."
  def format_time(nil), do: ""

  def format_time(%DateTime{} = datetime) do
    datetime
    |> DateTime.shift_zone!("America/Sao_Paulo")
    |> Calendar.strftime("%H:%M")
  rescue
    _ -> Calendar.strftime(datetime, "%H:%M")
  end

  @doc "Formats the selected timeline window."
  def window_label(starts_at, ends_at) do
    "#{format_time(starts_at)}–#{format_time(ends_at)}"
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

      %{
        channel: channel,
        programs: programs,
        current_program: current_program(programs, now),
        next_program: next_program(programs, now),
        provider_name: Map.get(provider_names, channel.provider_id, "Provedor")
      }
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

  defp default_start do
    DateTime.utc_now()
    |> DateTime.add(-15, :minute)
    |> DateTime.truncate(:second)
  end
end
