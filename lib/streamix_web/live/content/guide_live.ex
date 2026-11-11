defmodule StreamixWeb.Content.GuideLive do
  @moduledoc """
  Authenticated, provider-aware TV program guide.

  Lists the channels with programming in a three-hour window, favorites and
  real schedules first, a page at a time (more load as the list scrolls).
  Every few minutes the window reloads; the "now" line moves every minute.
  """

  use StreamixWeb, :live_view

  require Logger

  import StreamixWeb.App.Feedback, only: [empty_state: 1]

  import StreamixWeb.App.Filters,
    only: [filter_chip: 1, filter_strip: 1, provider_dropdown: 1, search_input: 1]

  alias Streamix.Library
  alias Streamix.SafeLog
  alias StreamixWeb.Content.{DisplayTitle, LocalTime, TvGuide}
  alias StreamixWeb.EpgComponents
  alias StreamixWeb.Helpers.ImageProxy

  @refresh_interval :timer.minutes(3)
  @tick_interval :timer.minutes(1)
  @shift_hours 2
  @page_size 30
  @category_prefix ~r/^(?:canais(?:\s+ao\s+vivo)?|tv(?:\s+ao\s+vivo)?)\s*[|:–-]\s*/iu

  @impl true
  def mount(_params, _session, socket) do
    library_key = socket.assigns.current_scope.library_key
    starts_at = TvGuide.default_start()

    if connected?(socket), do: :timer.send_interval(@tick_interval, :tick)

    {:ok,
     socket
     |> assign(
       now: DateTime.utc_now(),
       page_title: gettext("Guia de TV"),
       current_path: "/guide",
       rows: [],
       visible: [],
       shown: 0,
       categories: [],
       providers: [],
       selected_category: "all",
       selected_provider: nil,
       favorites_only: false,
       search: "",
       starts_at: starts_at,
       ends_at: TvGuide.window_end(starts_at),
       loading: true,
       load_generation: 0,
       refresh_ref: nil,
       favorite_ids: Library.list_favorite_ids(library_key, "live_channel")
     )
     |> stream_configure(:guide_rows, dom_id: &"guide-channel-#{&1.channel.id}")
     |> stream(:guide_rows, [])}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    starts_at = parse_window_start(params["at"])

    socket =
      assign(socket,
        selected_category: normalize_filter(params["category"]),
        selected_provider: parse_positive_integer(params["provider"]),
        favorites_only: params["favorites"] == "true",
        search: normalize_search(params["search"]),
        starts_at: starts_at,
        ends_at: TvGuide.window_end(starts_at),
        shown: 0
      )

    {:noreply, start_guide_load(socket)}
  end

  @impl true
  def handle_async({:load_guide, generation}, {:ok, result}, socket)
      when generation == socket.assigns.load_generation do
    cleaned_rows = result.rows |> Enum.map(&clean_row/1) |> one_per_name()
    cleaned_categories = clean_categories(result.categories, cleaned_rows)

    {:noreply,
     socket
     |> assign(
       now: DateTime.utc_now(),
       rows: cleaned_rows,
       categories: cleaned_categories,
       providers: result.providers,
       starts_at: result.starts_at,
       ends_at: result.ends_at,
       loading: false
     )
     |> restream(max(socket.assigns.shown, @page_size))
     |> schedule_refresh()}
  end

  def handle_async({:load_guide, generation}, {:exit, reason}, socket)
      when generation == socket.assigns.load_generation do
    Logger.warning("[TvGuide] load failed", reason: SafeLog.redact_inspect(reason))

    {:noreply,
     socket
     |> assign(loading: false, rows: [])
     |> restream(@page_size)
     |> put_flash(:error, gettext("Não foi possível atualizar o guia agora."))
     |> schedule_refresh()}
  end

  def handle_async({:load_guide, _stale_generation}, _result, socket), do: {:noreply, socket}

  @impl true
  def handle_event("filter", params, socket) do
    provider =
      case Map.fetch(params, "provider") do
        {:ok, val} when val in [nil, "", "all"] -> nil
        {:ok, val} -> parse_positive_integer(val)
        :error -> socket.assigns.selected_provider
      end

    path =
      guide_path(socket,
        search: Map.get(params, "search", socket.assigns.search),
        provider: provider
      )

    {:noreply, push_patch(socket, to: path)}
  end

  def handle_event("filter_provider", %{"provider" => provider}, socket) do
    provider_id =
      if provider in [nil, "", "all"], do: nil, else: parse_positive_integer(provider)

    {:noreply, push_patch(socket, to: guide_path(socket, provider: provider_id))}
  end

  def handle_event("filter_category", %{"category" => category}, socket) do
    {:noreply, push_patch(socket, to: guide_path(socket, category: normalize_filter(category)))}
  end

  def handle_event("toggle_favorites", _params, socket) do
    {:noreply,
     push_patch(socket, to: guide_path(socket, favorites: not socket.assigns.favorites_only))}
  end

  def handle_event("shift_window", %{"direction" => direction}, socket) do
    hours = if direction == "previous", do: -@shift_hours, else: @shift_hours
    starts_at = DateTime.add(socket.assigns.starts_at, hours, :hour)

    {:noreply, push_patch(socket, to: guide_path(socket, at: DateTime.to_unix(starts_at)))}
  end

  def handle_event("go_now", _params, socket) do
    {:noreply, push_patch(socket, to: guide_path(socket, at: nil))}
  end

  def handle_event("load_more", _params, socket) do
    %{visible: visible, shown: shown} = socket.assigns

    if shown < length(visible) do
      page = visible |> Enum.drop(shown) |> Enum.take(@page_size)

      {:noreply,
       socket
       |> assign(shown: shown + length(page))
       |> stream(:guide_rows, Enum.map(page, &present(&1, socket.assigns)))}
    else
      {:noreply, socket}
    end
  end

  def handle_event("toggle_favorite", %{"id" => id}, socket) do
    with {channel_id, ""} <- Integer.parse(id),
         row when not is_nil(row) <-
           Enum.find(socket.assigns.rows, &(&1.channel.id == channel_id)),
         {:ok, status} <-
           Library.toggle_favorite(
             socket.assigns.current_scope.library_key,
             "live_channel",
             channel_id,
             %{
               content_name: row.channel.name,
               content_icon: row.channel.stream_icon
             }
           ) do
      favorite_ids =
        case status do
          :added -> MapSet.put(socket.assigns.favorite_ids, channel_id)
          :removed -> MapSet.delete(socket.assigns.favorite_ids, channel_id)
        end

      {:noreply,
       socket
       |> assign(favorite_ids: favorite_ids)
       |> restream(socket.assigns.shown)}
    else
      _ -> {:noreply, socket}
    end
  end

  @impl true
  def handle_info(:refresh_guide, socket) do
    {:noreply, start_guide_load(assign(socket, refresh_ref: nil))}
  end

  # Moves the "now" line; the programs themselves move on the next reload.
  def handle_info(:tick, socket), do: {:noreply, assign(socket, now: DateTime.utc_now())}

  @impl true
  def terminate(_reason, socket) do
    cancel_refresh(socket.assigns[:refresh_ref])
    :ok
  end

  @doc "Strips redundant provider prefixes such as 'Canais | ' from category names."
  @spec clean_category(String.t() | nil) :: String.t() | nil
  def clean_category(nil), do: nil

  def clean_category(category) when is_binary(category) do
    cleaned =
      category
      |> String.trim()
      |> String.replace(@category_prefix, "")
      |> String.trim()

    if cleaned == "", do: nil, else: cleaned
  end

  defp clean_row(row) do
    programs = Enum.map(row.programs, &clean_program/1)
    current = row.current_program && clean_program(row.current_program)
    next = row.next_program && clean_program(row.next_program)
    channel = Map.update(row.channel, :name, "", &DisplayTitle.channel/1)

    %{row | channel: channel, programs: programs, current_program: current, next_program: next}
  end

  # The same channel from two providers, or in FHD, HD and SD, is listed
  # once: the copy with the fuller guide, then the one named first.
  defp one_per_name(rows) do
    rows
    |> Enum.sort_by(&{-length(&1.programs), String.length(to_string(&1.channel.name))})
    |> Enum.uniq_by(&same_channel_key(&1.channel.name))
  end

  @quality_suffix ~r/(?:[\s\-|]+(?:fhd|uhd|hd|sd|4k|h\.?265|hevc|alt|backup))+\s*$/iu

  @doc false
  def same_channel_key(name) do
    name
    |> to_string()
    |> String.replace(@quality_suffix, "")
    |> String.trim()
    |> String.downcase()
  end

  # Filters and orders the loaded rows and shows the first `count` of them
  # (at least a page), replacing what the list showed.
  defp restream(socket, count) do
    a = socket.assigns

    visible =
      a.rows
      |> TvGuide.filter(a.selected_category, a.favorites_only, a.favorite_ids)
      |> TvGuide.rank(a.favorite_ids, a.starts_at, a.ends_at)

    page = Enum.take(visible, max(count, @page_size))

    socket
    |> assign(visible: visible, shown: length(page))
    |> stream(:guide_rows, Enum.map(page, &present(&1, a)), reset: true)
  end

  # A row as the template draws it: favorite state and each program's place
  # in time worked out here, so the stream item carries everything it needs.
  defp present(row, assigns) do
    now = DateTime.utc_now()

    programs =
      Enum.map(row.programs, fn program ->
        program
        |> Map.put(:state, TvGuide.program_state(program, now))
        |> Map.put(
          :style,
          EpgComponents.program_style(program, assigns.starts_at, assigns.ends_at)
        )
      end)

    row
    |> Map.put(:programs, programs)
    |> Map.put(:favorite?, MapSet.member?(assigns.favorite_ids, row.channel.id))
    |> Map.put(:logo, ImageProxy.browser_image(row.channel.stream_icon))
  end

  defp clean_program(program) do
    Map.update(program, :category, nil, &clean_category/1)
  end

  defp clean_categories(categories, rows) do
    (categories ++ Enum.flat_map(rows, fn row -> Enum.map(row.programs, & &1.category) end))
    |> Enum.map(&clean_category/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp start_guide_load(socket) do
    if connected?(socket) do
      user = socket.assigns.current_scope.user
      generation = socket.assigns.load_generation + 1
      starts_at = socket.assigns.starts_at
      ends_at = socket.assigns.ends_at
      provider_id = socket.assigns.selected_provider
      search = socket.assigns.search

      socket
      |> cancel_scheduled_refresh()
      |> assign(loading: true, load_generation: generation)
      |> start_async({:load_guide, generation}, fn ->
        TvGuide.load(user,
          starts_at: starts_at,
          ends_at: ends_at,
          provider_id: provider_id,
          search: search
        )
      end)
    else
      socket
    end
  end

  defp schedule_refresh(socket) do
    socket = cancel_scheduled_refresh(socket)
    assign(socket, refresh_ref: Process.send_after(self(), :refresh_guide, @refresh_interval))
  end

  defp cancel_scheduled_refresh(socket) do
    cancel_refresh(socket.assigns[:refresh_ref])
    assign(socket, refresh_ref: nil)
  end

  defp cancel_refresh(nil), do: :ok
  defp cancel_refresh(ref), do: Process.cancel_timer(ref)

  defp guide_path(socket, overrides) do
    params = %{
      "search" => socket.assigns.search,
      "provider" => socket.assigns.selected_provider,
      "category" => socket.assigns.selected_category,
      "favorites" => socket.assigns.favorites_only,
      "at" => DateTime.to_unix(socket.assigns.starts_at)
    }

    params =
      Enum.reduce(overrides, params, fn {key, value}, acc ->
        Map.put(acc, Atom.to_string(key), value)
      end)

    query =
      params
      |> Enum.reject(fn
        {"search", value} -> value in [nil, ""]
        {"provider", value} -> is_nil(value)
        {"category", value} -> value in [nil, "", "all"]
        {"favorites", value} -> value != true
        {"at", value} -> is_nil(value)
      end)
      |> Map.new()

    if map_size(query) == 0, do: ~p"/guide", else: ~p"/guide?#{query}"
  end

  defp parse_window_start(nil), do: TvGuide.default_start()
  defp parse_window_start(""), do: TvGuide.default_start()

  defp parse_window_start(value) do
    with {unix, ""} <- Integer.parse(to_string(value)),
         {:ok, datetime} <- DateTime.from_unix(unix),
         true <- abs(DateTime.diff(datetime, DateTime.utc_now(), :day)) <= 7 do
      datetime
    else
      _ -> TvGuide.default_start()
    end
  end

  defp parse_positive_integer(nil), do: nil
  defp parse_positive_integer(""), do: nil

  defp parse_positive_integer(value) do
    case Integer.parse(to_string(value)) do
      {integer, ""} when integer > 0 -> integer
      _ -> nil
    end
  end

  defp normalize_filter(value) when is_binary(value) and value != "" do
    if value == "all" do
      "all"
    else
      clean_category(value) || "all"
    end
  end

  defp normalize_filter(_value), do: "all"

  defp normalize_search(value) when is_binary(value),
    do: value |> String.trim() |> String.slice(0, 120)

  defp normalize_search(_value), do: ""
end
