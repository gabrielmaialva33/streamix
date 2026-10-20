defmodule StreamixWeb.Content.GuideLive do
  @moduledoc "Authenticated, provider-aware TV program guide."

  use StreamixWeb, :live_view

  require Logger

  import StreamixWeb.App.Filters,
    only: [filter_chip: 1, filter_strip: 1, provider_dropdown: 1, search_input: 1]

  alias Streamix.Library
  alias StreamixWeb.Content.DisplayTitle
  alias StreamixWeb.Content.TvGuide
  alias StreamixWeb.Helpers.ImageProxy

  @refresh_interval :timer.minutes(1)
  @shift_hours 2
  @category_prefix ~r/^(?:canais(?:\s+ao\s+vivo)?|tv(?:\s+ao\s+vivo)?)\s*[|:–-]\s*/iu

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_scope.user

    {:ok,
     socket
     |> assign(
       page_title: gettext("Guia de TV"),
       current_path: "/guide",
       rows: [],
       all_rows: [],
       categories: [],
       providers: [],
       selected_category: "all",
       selected_provider: nil,
       favorites_only: false,
       search: "",
       starts_at: default_start(),
       ends_at: default_end(default_start()),
       loading: true,
       load_generation: 0,
       refresh_ref: nil,
       favorite_ids: Library.list_favorite_ids(user.id, "live_channel")
     )}
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
        ends_at: default_end(starts_at)
      )

    {:noreply, start_guide_load(socket)}
  end

  @impl true
  def handle_async({:load_guide, generation}, {:ok, result}, socket)
      when generation == socket.assigns.load_generation do
    cleaned_rows = Enum.map(result.rows, &clean_row/1)
    cleaned_categories = clean_categories(result.categories, cleaned_rows)

    rows =
      TvGuide.filter(
        cleaned_rows,
        socket.assigns.selected_category,
        socket.assigns.favorites_only,
        socket.assigns.favorite_ids
      )

    {:noreply,
     socket
     |> assign(
       rows: rows,
       all_rows: cleaned_rows,
       categories: cleaned_categories,
       providers: result.providers,
       starts_at: result.starts_at,
       ends_at: result.ends_at,
       loading: false
     )
     |> schedule_refresh()}
  end

  def handle_async({:load_guide, generation}, {:exit, reason}, socket)
      when generation == socket.assigns.load_generation do
    Logger.warning("[TvGuide] load failed: #{inspect(reason)}")

    {:noreply,
     socket
     |> assign(loading: false, rows: [], all_rows: [])
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

  def handle_event("toggle_favorite", %{"id" => id}, socket) do
    with {channel_id, ""} <- Integer.parse(id),
         row when not is_nil(row) <-
           Enum.find(socket.assigns.all_rows, &(&1.channel.id == channel_id)),
         {:ok, status} <-
           Library.toggle_favorite(
             socket.assigns.current_scope.user.id,
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

      rows =
        TvGuide.filter(
          socket.assigns.all_rows,
          socket.assigns.selected_category,
          socket.assigns.favorites_only,
          favorite_ids
        )

      {:noreply, assign(socket, favorite_ids: favorite_ids, rows: rows)}
    else
      _ -> {:noreply, socket}
    end
  end

  @impl true
  def handle_info(:refresh_guide, socket) do
    {:noreply, start_guide_load(assign(socket, refresh_ref: nil))}
  end

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

  defp parse_window_start(nil), do: default_start()
  defp parse_window_start(""), do: default_start()

  defp parse_window_start(value) do
    with {unix, ""} <- Integer.parse(to_string(value)),
         {:ok, datetime} <- DateTime.from_unix(unix),
         true <- abs(DateTime.diff(datetime, DateTime.utc_now(), :day)) <= 7 do
      datetime
    else
      _ -> default_start()
    end
  end

  defp default_start do
    DateTime.utc_now()
    |> DateTime.add(-15, :minute)
    |> DateTime.truncate(:second)
  end

  defp default_end(starts_at), do: DateTime.add(starts_at, 3, :hour)

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
