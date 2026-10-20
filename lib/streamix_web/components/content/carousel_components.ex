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
    <section>
      <StreamixWeb.Content.NavigationComponents.section_header
        title="Para você"
        icon="hero-sparkles-solid"
        ai_powered={true}
      />

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
        <div class="media-shelf-track">
          <div
            :for={item <- @recommendations}
            class="media-shelf-card media-shelf-card--poster media-shelf-card--poster-featured"
          >
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
