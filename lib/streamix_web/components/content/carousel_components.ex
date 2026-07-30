defmodule StreamixWeb.Content.CarouselComponents do
  @moduledoc "Personalized recommendation components."
  use Phoenix.Component

  import StreamixWeb.CoreComponents
  import StreamixWeb.Content.CardComponents

  @doc """
  Renders a "Para Você" AI recommendations section.
  """
  attr :recommendations, :list, required: true
  attr :on_play, :string, default: "play_movie"
  attr :on_details, :string, default: "show_details"

  def for_you_section(assigns) do
    ~H"""
    <section class="px-[4%]">
      <div class="flex items-center justify-between mb-3 sm:mb-4">
        <h2 class="flex items-center gap-2 text-base sm:text-xl font-semibold text-text-primary">
          <.icon name="hero-sparkles-solid" class="size-4 sm:size-5 text-warning" /> Para Você
        </h2>
      </div>

      <%= if @recommendations == [] do %>
        <div class="flex flex-col items-center justify-center py-12 sm:py-16 rounded-lg border border-glass-border bg-surface-elevated/30">
          <.icon name="hero-sparkles" class="size-12 sm:size-16 text-text-muted mb-4" />
          <h3 class="text-base sm:text-lg font-medium text-text-secondary mb-2">
            Ainda estamos conhecendo você
          </h3>
          <p class="text-sm text-text-muted text-center max-w-md px-4">
            Continue assistindo para receber recomendações personalizadas baseadas no seu gosto.
          </p>
        </div>
      <% else %>
        <%!-- Mobile: 3-column grid --%>
        <div class="grid grid-cols-3 gap-2 sm:hidden">
          <.movie_card
            :for={item <- Enum.take(@recommendations, 6)}
            movie={item}
            show_favorite={false}
            on_play={@on_play}
            on_details={@on_details}
          />
        </div>
        <%!-- Desktop: horizontal scroll --%>
        <div class="hidden sm:flex sm:gap-4 sm:overflow-x-auto py-1 sm:py-2 scrollbar-hide scroll-smooth">
          <div :for={item <- @recommendations} class="flex-shrink-0 w-[160px] lg:w-[180px]">
            <.movie_card
              movie={item}
              show_favorite={false}
              on_play={@on_play}
              on_details={@on_details}
            />
          </div>
        </div>
      <% end %>
    </section>
    """
  end
end
