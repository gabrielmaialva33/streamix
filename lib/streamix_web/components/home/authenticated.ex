defmodule StreamixWeb.Home.Authenticated do
  @moduledoc """
  Authenticated home composition.
  """

  use Phoenix.Component
  use StreamixWeb, :verified_routes

  import StreamixWeb.AppComponents
  import StreamixWeb.ContentComponents
  import StreamixWeb.CoreComponents
  import StreamixWeb.Home.Carousel
  import StreamixWeb.Home.Hero

  def render_authenticated_home(assigns) do
    ~H"""
    <.render_hero_section
      featured={@featured}
      stats={@stats}
      current_scope={@current_scope}
      featured_favorite={@featured_favorite}
    />

    <div class="space-y-6 sm:space-y-8 pb-12">
      <.premium_cta_banner id="home-premium-cta" current_scope={@current_scope} />

      <.render_content_carousel
        :if={@history != []}
        title="Continue Assistindo"
        items={@history}
        type={:history}
      />

      <.render_content_carousel
        :if={@favorites != []}
        title="Minha Lista"
        items={@favorites}
        type={:favorites}
      />

      <.for_you_section :if={@recommendations != []} recommendations={@recommendations} />

      <.render_ai_trending_section
        :if={@trending != []}
        items={@trending}
        genre_filters={@genre_filters}
        period_filters={@period_filters}
        selected_genre={@trending_genre}
        selected_period={@trending_period}
        ai_powered={true}
        progress_map={@movie_progress}
      />

      <.render_content_carousel
        :if={@new_releases != []}
        title="Lançamentos"
        items={@new_releases}
        type={:movies}
        icon="hero-sparkles"
        progress_map={@movie_progress}
        see_more_path={~p"/browse/movies?sort=new"}
      />

      <.render_top_10 :if={@top_10 != []} title="Top 10 Filmes" items={@top_10} />

      <.render_content_carousel
        :if={@movies != []}
        title="Filmes em Destaque"
        items={@movies}
        type={:movies}
        progress_map={@movie_progress}
      />

      <.render_ai_series_section
        :if={@series != []}
        items={@series}
        genre_filters={@genre_filters}
        selected_genre={@series_genre}
        ai_powered={true}
        progress_map={@series_progress}
      />

      <.render_ai_channels_section
        :if={@channels != []}
        items={@channels}
        category_filters={@channel_filters}
        selected_category={@channels_category}
        ai_powered={true}
      />

      <div
        :if={@movies == [] && @series == [] && @channels == []}
        class="px-[4%] py-24 text-center"
      >
        <.icon name="hero-film" class="size-16 text-text-muted mx-auto mb-4" />
        <h2 class="text-2xl font-bold text-text-primary mb-2">Nenhum conteúdo disponível</h2>
        <p class="text-text-secondary max-w-md mx-auto mb-6">
          Configure um provedor IPTV para começar a explorar filmes, séries e canais ao vivo.
        </p>
        <.link
          navigate={~p"/providers"}
          class="inline-flex items-center gap-2 px-6 py-3 bg-brand text-white font-semibold rounded-md hover:bg-brand-hover transition-colors"
        >
          <.icon name="hero-plus" class="size-5" /> Adicionar Provedor
        </.link>
      </div>
    </div>
    """
  end
end
