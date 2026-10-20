defmodule StreamixWeb.GameComponents do
  @moduledoc false
  use StreamixWeb, :html

  attr :games, :any, required: true
  attr :count, :integer, required: true

  def rail(assigns) do
    ~H"""
    <section :if={@count > 0} id="games-today" aria-labelledby="games-today-title" class="space-y-3">
      <StreamixWeb.Content.NavigationComponents.section_header
        id="games-today-title"
        title="Jogos de hoje"
        icon="hero-trophy"
      >
        <:actions><span class="text-xs text-text-muted">Horário de Brasília</span></:actions>
      </StreamixWeb.Content.NavigationComponents.section_header>
      <div id="games-today-list" phx-update="stream" class="flex gap-4 overflow-x-auto pb-3 snap-x">
        <article
          :for={{dom_id, game} <- @games}
          id={dom_id}
          class="w-72 shrink-0 snap-start rounded-xl border border-white/10 bg-surface p-4"
        >
          <.link
            href={~p"/watch/live_channel/#{game.channel_id}"}
            class="block space-y-3"
            aria-label={"Assistir #{game.title}"}
          >
            <div class="flex items-center justify-between gap-2">
              <span class="truncate text-xs text-text-muted">{game.league}</span>
              <.badge
                :if={game.live}
                variant="live"
                data-live="true"
                class="shrink-0"
              >
                AO VIVO
              </.badge>
              <time
                :if={!game.live}
                datetime={DateTime.to_iso8601(game.starts_at)}
                class="text-sm font-semibold"
              >{game.start_time}</time>
            </div>
            <div
              :for={{team, index} <- Enum.with_index([game.home, game.away])}
              class="flex min-w-0 items-center gap-3"
            >
              <div id={"#{dom_id}-crest-#{index}"} phx-hook="ImageFallback" class="size-8 shrink-0">
                <img
                  :if={team.logo_url not in [nil, ""]}
                  src={team.logo_url}
                  alt=""
                  width="32"
                  height="32"
                  loading="lazy"
                  class="size-8 object-contain"
                  data-fallback-target
                />
                <span
                  data-fallback
                  aria-hidden="true"
                  class={[
                    "flex size-8 items-center justify-center rounded bg-surface-hover text-xs font-semibold text-text-secondary",
                    team.logo_url not in [nil, ""] && "hidden"
                  ]}
                >{team_monogram(team.name)}</span>
              </div>
              <span class="min-w-0 truncate font-semibold">{team.name}</span>
            </div>
          </.link>
        </article>
      </div>
    </section>
    """
  end

  defp team_monogram(name) when is_binary(name) do
    name |> String.split() |> Enum.take(2) |> Enum.map_join(&String.first/1) |> String.upcase()
  end

  defp team_monogram(_), do: "?"
end
