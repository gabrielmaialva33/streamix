defmodule StreamixWeb.GameComponents do
  @moduledoc false
  use StreamixWeb, :html

  attr :games, :any, required: true
  attr :count, :integer, required: true

  def rail(assigns) do
    ~H"""
    <section :if={@count > 0} id="games-today" aria-labelledby="games-today-title" class="space-y-3">
      <div class="flex items-baseline justify-between gap-3">
        <h2 id="games-today-title" class="text-xl font-bold">Jogos de hoje</h2>
        <span class="text-xs text-text-muted">Horário de Brasília</span>
      </div>
      <div id="games-today-list" phx-update="stream" class="flex gap-4 overflow-x-auto pb-3 snap-x">
        <article
          :for={{dom_id, game} <- @games}
          id={dom_id}
          class="w-72 shrink-0 snap-start rounded-xl border border-white/10 bg-surface p-4"
        >
          <.link
            navigate={~p"/watch/live_channel/#{game.channel_id}"}
            class="block space-y-3"
            aria-label={"Assistir #{game.title}"}
          >
            <div class="flex items-center justify-between gap-2">
              <span class="truncate text-xs text-text-muted">{game.league}</span>
              <span
                :if={game.live}
                data-live="true"
                class="shrink-0 rounded bg-red-600 px-2 py-1 text-xs font-bold text-white"
              >AO VIVO</span>
              <time
                :if={!game.live}
                datetime={DateTime.to_iso8601(game.starts_at)}
                class="text-sm font-semibold"
              >{game.start_time}</time>
            </div>
            <div :for={team <- [game.home, game.away]} class="flex items-center gap-3">
              <img
                :if={team.logo_url}
                src={team.logo_url}
                alt=""
                width="32"
                height="32"
                loading="lazy"
                class="size-8 object-contain"
              />
              <span class="truncate font-semibold">{team.name}</span>
            </div>
          </.link>
        </article>
      </div>
    </section>
    """
  end
end
