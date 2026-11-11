defmodule StreamixWeb.StationsLive do
  @moduledoc """
  The 24h stations, laid out like a TV guide.

  Streamix's own stations come first: a featured one with what plays, from
  when to when, and what follows, next to a numbered channel list. On a wide
  screen picking a channel previews it in the feature; on a phone it tunes
  straight in. Below sit the providers' own 24h channels ("24H | Séries",
  "24H | Desenhos"...), grouped by kind.

  Everything updates itself: each station's server announces a new title on
  its PubSub topic, viewer counts arrive as Presence diffs, and a coarse
  tick moves the progress bars. `/stations/:slug` tunes in, computing the
  offset at the moment of the tap.
  """

  use StreamixWeb, :live_view

  import StreamixWeb.App.Feedback, only: [empty_state: 1]

  alias Streamix.{Catalog, Programming}
  alias StreamixWeb.Presence
  alias StreamixWeb.StationPaths

  @tick :timer.seconds(30)

  @impl true
  def mount(%{"slug" => slug}, _session, socket) do
    case Programming.now_playing(slug) do
      {:ok, %{slot: slot}} ->
        {:ok, redirect(socket, to: StationPaths.watch(slug, slot))}

      {:error, _reason} ->
        {:ok,
         socket
         |> put_flash(:error, "Esse canal está fora do ar agora.")
         |> redirect(to: ~p"/stations")}
    end
  end

  def mount(_params, _session, socket) do
    playing = Programming.list_now_playing()
    scope = socket.assigns.current_scope

    if connected?(socket) do
      for %{station: station} <- playing do
        Programming.subscribe(station.slug)
        Phoenix.PubSub.subscribe(Streamix.PubSub, StationPaths.viewers_topic(station.slug))
      end

      :timer.send_interval(@tick, :tick)
    end

    numbers = playing |> Enum.with_index(1) |> Map.new(fn {%{station: s}, n} -> {s.slug, n} end)
    cards = Enum.map(playing, &card(&1, numbers))
    selected = featured_slug(cards)
    cards = Enum.map(cards, &%{&1 | selected: &1.id == selected})
    {series, movies} = Enum.split_with(cards, &(&1.kind == "series"))

    groups =
      Catalog.list_round_the_clock_channels(scope.user.id,
        show_adult: scope.user.show_adult_content
      )

    tab = groups |> List.first() |> then(&(&1 && &1.label))

    {:ok,
     socket
     |> assign(
       page_title: "Canais 24h",
       current_path: "/stations",
       numbers: numbers,
       selected: selected,
       hero: Enum.find(cards, &(&1.id == selected)),
       station_count: length(cards),
       movie_count: length(movies),
       series_count: length(series),
       groups: Map.new(groups, &{&1.label, &1.channels}),
       tabs: Enum.map(groups, &{&1.label, length(&1.channels)}),
       tab: tab
     )
     |> stream(:movie_stations, movies)
     |> stream(:series_stations, series)
     |> stream(:list_channels, channels_for(groups, tab))}
  end

  @impl true
  def handle_event("select", %{"slug" => slug}, socket) do
    if Map.has_key?(socket.assigns.numbers, slug) do
      previous = socket.assigns.selected

      {:noreply,
       socket
       |> assign(selected: slug)
       |> refresh(previous)
       |> refresh(slug)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("tab", %{"label" => label}, socket) do
    case Map.fetch(socket.assigns.groups, label) do
      {:ok, channels} ->
        {:noreply, socket |> assign(tab: label) |> stream(:list_channels, channels, reset: true)}

      :error ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:station_slot, slug, _slot}, socket), do: {:noreply, refresh(socket, slug)}

  def handle_info(%Phoenix.Socket.Broadcast{event: "presence_diff", topic: topic}, socket) do
    {:noreply, refresh(socket, String.replace_prefix(topic, "station_viewers:", ""))}
  end

  def handle_info(:tick, socket) do
    socket =
      Enum.reduce(Programming.list_now_playing(), socket, fn playing, socket ->
        insert_card(socket, card(playing, socket.assigns.numbers))
      end)

    {:noreply, socket}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp refresh(socket, slug) do
    case Programming.now_playing(slug) do
      {:ok, playing} ->
        insert_card(socket, card(playing, socket.assigns.numbers))

      {:error, _reason} ->
        socket
        |> stream_delete_by_dom_id(:movie_stations, "movie_stations-#{slug}")
        |> stream_delete_by_dom_id(:series_stations, "series_stations-#{slug}")
    end
  end

  defp insert_card(socket, card) do
    card = %{card | selected: card.id == socket.assigns.selected}
    socket = if card.selected, do: assign(socket, hero: card), else: socket
    stream_insert(socket, stream_for(card), card)
  end

  defp stream_for(%{kind: "series"}), do: :series_stations
  defp stream_for(_card), do: :movie_stations

  # The most watched station leads; with nobody watching, the first one.
  defp featured_slug([]), do: nil

  defp featured_slug(cards) do
    cards |> Enum.max_by(& &1.viewers, fn -> hd(cards) end) |> Map.fetch!(:id)
  end

  defp channels_for(_groups, nil), do: []

  defp channels_for(groups, tab) do
    Enum.find_value(groups, [], fn group -> if group.label == tab, do: group.channels end)
  end

  defp card(%{station: station, slot: slot}, numbers) do
    {headline, detail} = headline(slot.item)

    %{
      id: station.slug,
      number:
        numbers |> Map.get(station.slug, 0) |> Integer.to_string() |> String.pad_leading(2, "0"),
      kind: station.kind,
      name: station.name,
      poster: slot.item["poster"],
      headline: headline,
      detail: detail,
      now: StationPaths.label(slot.item),
      next: StationPaths.label(slot.next),
      starts: StationPaths.clock(slot.started_at),
      ends: StationPaths.clock(slot.ends_at),
      progress: round(Programming.progress(slot) * 100),
      viewers: StationPaths.viewers_topic(station.slug) |> Presence.list() |> map_size(),
      selected: false
    }
  end

  # The feature's two lines: the film and its year, or the series and the
  # episode ("T4:E2 · A limpeza do pátio").
  defp headline(%{"subtitle" => subtitle} = item) when is_binary(subtitle) do
    case String.split(StationPaths.label(item), " · ", parts: 2) do
      [title, rest] -> {title, rest}
      [title] -> {title, nil}
    end
  end

  defp headline(item), do: {StationPaths.label(item), nil}

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-10 py-6 sm:py-8">
      <.page_header
        id="stations-page-header"
        title="Canais 24h"
        icon="hero-signal"
        subtitle="Programação contínua: entre e caia no mesmo minuto que todo mundo."
      />

      <div
        :if={@station_count > 0}
        class="grid grid-cols-1 gap-6 lg:grid-cols-[minmax(0,1fr)_22rem] xl:grid-cols-[minmax(0,1fr)_26rem]"
      >
        <.feature :if={@hero} station={@hero} />

        <nav
          id="station-list"
          aria-label="Canais Streamix"
          class="min-w-0 space-y-4 lg:max-h-[34rem] lg:overflow-y-auto lg:pr-1"
        >
          <.station_rows
            :if={@movie_count > 0}
            id="movie-stations"
            title="Filmes"
            stations={@streams.movie_stations}
          />
          <.station_rows
            :if={@series_count > 0}
            id="series-stations"
            title="Séries"
            stations={@streams.series_stations}
          />
        </nav>
      </div>

      <div :if={@station_count == 0} id="stations-empty">
        <.empty_state
          icon="hero-signal"
          title="Nenhum canal no ar"
          message="A programação está sendo montada. Volte em alguns minutos."
        />
      </div>

      <section :if={@tabs != []} id="list-channels" class="space-y-4">
        <div>
          <h2 class="text-xl font-semibold text-text-primary">Das suas listas IPTV</h2>
          <p class="mt-1 text-sm text-text-secondary">
            Canais dos provedores que passam a mesma série, desenho ou tema o dia todo.
          </p>
        </div>

        <div
          role="tablist"
          class="-mx-4 flex gap-2 overflow-x-auto px-4 pb-1 sm:mx-0 sm:flex-wrap sm:px-0"
        >
          <button
            :for={{label, count} <- @tabs}
            id={"list-tab-#{slug(label)}"}
            type="button"
            role="tab"
            aria-selected={to_string(label == @tab)}
            phx-click="tab"
            phx-value-label={label}
            class={[
              "inline-flex min-h-10 shrink-0 items-center gap-2 rounded-full border px-4 text-sm font-medium transition-colors focus:outline-none focus:ring-2 focus:ring-brand",
              if(label == @tab,
                do: "border-brand bg-brand text-white",
                else: "border-border bg-surface text-text-secondary hover:text-text-primary"
              )
            ]}
          >
            {label} <span class="tabular-nums opacity-70">{count}</span>
          </button>
        </div>

        <div
          id="list-channel-grid"
          phx-update="stream"
          class="grid grid-cols-3 gap-3 sm:grid-cols-4 md:grid-cols-5 lg:grid-cols-6 xl:grid-cols-8"
        >
          <.link
            :for={{dom_id, channel} <- @streams.list_channels}
            id={dom_id}
            navigate={~p"/watch/live_channel/#{channel.id}"}
            class="group block space-y-2 focus:outline-none"
          >
            <div class="relative aspect-[2/3] overflow-hidden rounded-lg border border-border bg-surface transition-colors group-hover:border-brand/60 group-focus:ring-2 group-focus:ring-brand">
              <img
                :if={channel.poster}
                src={channel.poster}
                alt=""
                loading="lazy"
                class="size-full object-cover"
              />
              <div
                :if={!channel.poster && channel.logo}
                class="flex size-full items-center justify-center p-4"
              >
                <img
                  src={channel.logo}
                  alt=""
                  loading="lazy"
                  class="max-h-full max-w-full object-contain"
                />
              </div>
              <div
                :if={!channel.poster && !channel.logo}
                class="flex size-full items-end bg-gradient-to-br from-surface-hover to-surface p-3"
              >
                <span class="line-clamp-4 text-base font-bold leading-snug text-text-primary">
                  {channel.name}
                </span>
              </div>
              <span class="absolute left-2 top-2 rounded bg-black/70 px-1.5 py-0.5 text-[10px] font-semibold text-white">
                24h
              </span>
            </div>
            <p
              :if={channel.poster || channel.logo}
              class="line-clamp-2 text-xs font-medium text-text-secondary group-hover:text-text-primary"
            >
              {channel.name}
            </p>
          </.link>
        </div>
      </section>
    </div>
    """
  end

  # The selected station, large: its picture undimmed on the right, the
  # text on a gradient that keeps it readable on any poster.
  defp feature(assigns) do
    ~H"""
    <section
      id="station-feature"
      aria-live="polite"
      class="relative isolate flex min-h-[22rem] min-w-0 overflow-hidden rounded-2xl border border-border bg-surface sm:min-h-[26rem] lg:min-h-[34rem]"
    >
      <img
        :if={@station.poster}
        src={@station.poster}
        alt=""
        class="absolute inset-0 -z-10 size-full object-cover sm:left-1/3 sm:w-2/3"
      />
      <div class="absolute inset-0 -z-10 bg-gradient-to-t from-surface via-surface/85 to-surface/10 sm:bg-gradient-to-r sm:from-surface sm:via-surface/90 sm:to-transparent">
      </div>

      <div class="flex w-full flex-col justify-end gap-4 p-5 sm:max-w-xl sm:p-8">
        <div class="flex flex-wrap items-center gap-3 text-sm">
          <span class="inline-flex items-center gap-1.5 rounded bg-brand px-2 py-0.5 text-xs font-bold text-white">
            <span class="size-1.5 rounded-full bg-white motion-safe:animate-pulse"></span> Ao vivo
          </span>
          <span class="font-medium text-text-secondary">
            <span class="tabular-nums">{@station.number}</span> {@station.name}
          </span>
        </div>

        <div class="space-y-1">
          <h2
            id="station-feature-title"
            class="text-3xl font-bold leading-tight text-text-primary sm:text-4xl"
          >
            {@station.headline}
          </h2>
          <p :if={@station.detail} class="text-base text-text-secondary sm:text-lg">
            {@station.detail}
          </p>
        </div>

        <div class="flex items-center gap-3 text-sm tabular-nums text-text-secondary">
          <span>{@station.starts}</span>
          <div class="h-1.5 flex-1 overflow-hidden rounded-full bg-text-primary/15">
            <div class="h-full rounded-full bg-brand" style={"width: #{@station.progress}%"}></div>
          </div>
          <span>{@station.ends}</span>
        </div>

        <p class="truncate text-sm text-text-secondary">
          <span class="text-text-muted">A seguir</span> {@station.next}
        </p>

        <div class="flex flex-wrap items-center gap-4 pt-1">
          <.link
            id="station-feature-watch"
            navigate={~p"/stations/#{@station.id}"}
            class="inline-flex min-h-11 items-center gap-2 rounded-lg bg-brand px-5 font-semibold text-white transition-colors hover:bg-brand/90 focus:outline-none focus:ring-2 focus:ring-brand focus:ring-offset-2 focus:ring-offset-surface"
          >
            <.icon name="hero-play-solid" class="size-5" /> Assistir ao vivo
          </.link>
          <span
            :if={@station.viewers > 0}
            class="flex items-center gap-1.5 text-sm text-text-secondary"
          >
            <.icon name="hero-eye" class="size-4" /> {@station.viewers} assistindo
          </span>
        </div>
      </div>
    </section>
    """
  end

  # Numbered like TV channels. On a phone a row tunes in; on a wide screen it
  # previews the channel in the feature and the play button tunes in.
  defp station_rows(assigns) do
    ~H"""
    <section class="space-y-1">
      <h3 class="px-3 text-sm font-semibold text-text-muted">{@title}</h3>
      <ul id={@id} phx-update="stream" class="space-y-1">
        <li
          :for={{dom_id, station} <- @stations}
          id={dom_id}
          data-selected={to_string(station.selected)}
          class={[
            "group relative flex items-center gap-3 rounded-xl px-3 py-2 transition-colors",
            if(station.selected,
              do: "bg-surface-hover ring-1 ring-brand/50",
              else: "hover:bg-surface-hover/60"
            )
          ]}
        >
          <.link
            navigate={~p"/stations/#{station.id}"}
            class="absolute inset-0 rounded-xl focus:outline-none focus:ring-2 focus:ring-brand lg:hidden"
            aria-label={"Assistir #{station.name}"}
          ></.link>
          <button
            type="button"
            phx-click="select"
            phx-value-slug={station.id}
            class="absolute inset-0 hidden rounded-xl focus:outline-none focus:ring-2 focus:ring-brand lg:block"
            aria-label={"Ver o que passa em #{station.name}"}
          ></button>

          <span class="w-6 shrink-0 text-right text-sm font-semibold tabular-nums text-text-muted">
            {station.number}
          </span>
          <div class="h-12 w-20 shrink-0 overflow-hidden rounded-md bg-background">
            <img
              :if={station.poster}
              src={station.poster}
              alt=""
              loading="lazy"
              class="size-full object-cover"
            />
          </div>
          <div class="min-w-0 flex-1">
            <p class="truncate text-sm font-semibold text-text-primary">{station.name}</p>
            <p class="truncate text-xs text-text-secondary">{station.now}</p>
            <div class="mt-1.5 h-0.5 overflow-hidden rounded-full bg-text-primary/10">
              <div class="h-full bg-brand" style={"width: #{station.progress}%"}></div>
            </div>
          </div>
          <span
            :if={station.viewers > 0}
            class="flex shrink-0 items-center gap-1 text-xs tabular-nums text-text-secondary"
            title={"#{station.viewers} assistindo"}
          >
            <.icon name="hero-eye" class="size-3.5" />{station.viewers}
          </span>
          <.link
            navigate={~p"/stations/#{station.id}"}
            class="relative z-10 hidden size-9 shrink-0 items-center justify-center rounded-full text-text-secondary transition-colors hover:bg-brand hover:text-white focus:outline-none focus:ring-2 focus:ring-brand lg:flex"
            aria-label={"Assistir #{station.name}"}
          >
            <.icon name="hero-play-solid" class="size-4" />
          </.link>
        </li>
      </ul>
    </section>
    """
  end

  defp slug(label) do
    label
    |> String.normalize(:nfd)
    |> String.replace(~r/\p{M}/u, "")
    |> String.replace(~r/[^a-zA-Z0-9]+/u, "-")
    |> String.downcase()
  end
end
