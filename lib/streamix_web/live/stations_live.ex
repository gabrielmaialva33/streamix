defmodule StreamixWeb.StationsLive do
  @moduledoc """
  The 24h stations: what each one plays right now, how far into it, what
  follows and how many people are watching.

  Cards update themselves: each station's server announces a new film on
  its PubSub topic, viewer counts arrive as Presence diffs, and a coarse
  tick moves the progress bars. `/stations/:slug` tunes in, computing the
  offset at the moment of the tap.
  """

  use StreamixWeb, :live_view

  import StreamixWeb.App.Feedback, only: [empty_state: 1]

  alias Streamix.Programming
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

    if connected?(socket) do
      for %{station: station} <- playing do
        Programming.subscribe(station.slug)
        Phoenix.PubSub.subscribe(Streamix.PubSub, StationPaths.viewers_topic(station.slug))
      end

      :timer.send_interval(@tick, :tick)
    end

    {:ok,
     socket
     |> assign(page_title: "Canais 24h", current_path: "/stations", count: length(playing))
     |> stream(:stations, Enum.map(playing, &card/1))}
  end

  @impl true
  def handle_info({:station_slot, slug, _slot}, socket), do: {:noreply, refresh(socket, slug)}

  def handle_info(%Phoenix.Socket.Broadcast{event: "presence_diff", topic: topic}, socket) do
    {:noreply, refresh(socket, String.replace_prefix(topic, "station_viewers:", ""))}
  end

  def handle_info(:tick, socket) do
    cards = Enum.map(Programming.list_now_playing(), &card/1)
    {:noreply, stream(socket, :stations, cards)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp refresh(socket, slug) do
    case Programming.now_playing(slug) do
      {:ok, playing} -> stream_insert(socket, :stations, card(playing))
      {:error, _reason} -> stream_delete_by_dom_id(socket, :stations, "stations-#{slug}")
    end
  end

  defp card(%{station: station, slot: slot}) do
    %{
      id: station.slug,
      name: station.name,
      description: station.description,
      now: slot.item,
      next: slot.next,
      progress: round(Programming.progress(slot) * 100),
      remaining: div(DateTime.diff(slot.ends_at, DateTime.utc_now(), :second), 60),
      viewers: StationPaths.viewers_topic(station.slug) |> Presence.list() |> map_size()
    }
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6 py-6 sm:py-8">
      <.page_header id="stations-page-header" title="Canais 24h" icon="hero-signal" />
      <p class="max-w-2xl text-sm text-text-secondary">
        Filmes passando agora, como na TV: entre e caia no mesmo minuto que todo mundo.
      </p>

      <div
        id="stations-grid"
        phx-update="stream"
        class="grid grid-cols-1 gap-4 sm:grid-cols-2 xl:grid-cols-3"
      >
        <.link
          :for={{dom_id, station} <- @streams.stations}
          id={dom_id}
          navigate={~p"/stations/#{station.id}"}
          class="group relative flex min-h-56 flex-col justify-end overflow-hidden rounded-xl border border-border bg-surface focus:outline-none focus:ring-2 focus:ring-brand"
        >
          <img
            :if={station.now["poster"]}
            src={station.now["poster"]}
            alt=""
            loading="lazy"
            class="absolute inset-0 size-full object-cover opacity-40 transition-opacity group-hover:opacity-60"
          />
          <div class="absolute inset-0 bg-gradient-to-t from-black via-black/70 to-transparent"></div>

          <div class="absolute left-4 right-4 top-4 flex items-center justify-between">
            <span class="rounded bg-brand px-2 py-0.5 text-[11px] font-bold uppercase tracking-wide text-white">
              Ao vivo
            </span>
            <span
              :if={station.viewers > 0}
              class="flex items-center gap-1 rounded-full bg-black/60 px-2 py-0.5 text-xs text-white"
            >
              <.icon name="hero-eye" class="size-3.5" />
              {station.viewers} assistindo
            </span>
          </div>

          <div class="relative space-y-2 p-4">
            <h2 class="text-lg font-semibold text-white">{station.name}</h2>
            <p class="truncate text-sm text-white/90">
              <span class="text-white/60">Agora:</span>
              {station.now["title"]}{if station.now["year"], do: " (#{station.now["year"]})"}
            </p>
            <div class="h-1 w-full overflow-hidden rounded-full bg-white/20">
              <div class="h-full rounded-full bg-brand" style={"width: #{station.progress}%"}></div>
            </div>
            <div class="flex items-center justify-between gap-3 text-xs text-white/60">
              <span class="truncate">A seguir: {station.next["title"]}</span>
              <span class="shrink-0">faltam {max(station.remaining, 1)} min</span>
            </div>
          </div>
        </.link>
      </div>

      <div :if={@count == 0} id="stations-empty">
        <.empty_state
          icon="hero-signal"
          title="Nenhum canal no ar"
          message="A programação está sendo montada. Volte em alguns minutos."
        />
      </div>
    </div>
    """
  end
end
