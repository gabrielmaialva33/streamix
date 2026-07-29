defmodule StreamixWeb.Home.Carousel do
  @moduledoc """
  Carousel sections for the home surface.
  """

  use Phoenix.Component
  use StreamixWeb, :verified_routes

  import StreamixWeb.Content.NavigationComponents
  import StreamixWeb.CoreComponents
  import StreamixWeb.Home.Cards
  import StreamixWeb.Home.Helpers

  alias StreamixWeb.Helpers.ImageProxy

  def carousel_arrows(assigns) do
    ~H"""
    <div
      id={@id}
      phx-hook=".ScrollArrows"
      class="relative sm:group/carousel"
    >
      {render_slot(@inner_block)}
      <button
        type="button"
        data-scroll-dir="left"
        class="carousel-arrow-left absolute left-0 top-0 bottom-0 z-10 w-10 flex items-center justify-center bg-gradient-to-r from-background/90 to-transparent opacity-0 group-hover/carousel:opacity-100 transition-opacity cursor-pointer disabled:hidden"
      >
        <.icon name="hero-chevron-left" class="size-6 text-white" />
      </button>
      <button
        type="button"
        data-scroll-dir="right"
        class="carousel-arrow-right absolute right-0 top-0 bottom-0 z-10 w-10 flex items-center justify-center bg-gradient-to-l from-background/90 to-transparent opacity-0 group-hover/carousel:opacity-100 transition-opacity cursor-pointer disabled:hidden"
      >
        <.icon name="hero-chevron-right" class="size-6 text-white" />
      </button>
    </div>

    <script :type={Phoenix.LiveView.ColocatedHook} name=".ScrollArrows">
      export default {
        mounted() {
          this.track = this.el.querySelector('[data-carousel-track]')
          if (!this.track) return

          this.leftBtn = this.el.querySelector('[data-scroll-dir="left"]')
          this.rightBtn = this.el.querySelector('[data-scroll-dir="right"]')

          this.leftBtn?.addEventListener('click', () => this.scroll(-1))
          this.rightBtn?.addEventListener('click', () => this.scroll(1))
          this.track.addEventListener('scroll', () => this.updateArrows(), { passive: true })

          requestAnimationFrame(() => this.updateArrows())
        },

        scroll(dir) {
          const amount = this.track.clientWidth * 0.8
          this.track.scrollBy({ left: dir * amount, behavior: 'smooth' })
        },

        updateArrows() {
          if (!this.track) return
          const { scrollLeft, scrollWidth, clientWidth } = this.track
          const atStart = scrollLeft <= 4
          const atEnd = scrollLeft + clientWidth >= scrollWidth - 4

          if (this.leftBtn) this.leftBtn.disabled = atStart
          if (this.rightBtn) this.rightBtn.disabled = atEnd
        }
      }
    </script>
    """
  end

  def render_content_carousel(assigns) do
    assigns =
      assigns
      |> assign_new(:carousel_id, fn -> build_carousel_id(assigns.type, assigns[:title]) end)
      |> assign_new(:see_more_path, fn -> get_see_more_path(assigns.type, assigns.items) end)
      |> assign_new(:icon, fn -> nil end)
      |> assign_new(:progress_map, fn -> %{} end)
      |> assign_new(:favorites_map, fn -> MapSet.new() end)

    ~H"""
    <div class="px-[4%]">
      <div class="flex items-center justify-between mb-3 sm:mb-4">
        <h2 class="text-base sm:text-xl font-semibold text-text-primary flex items-center gap-2">
          <.icon :if={@icon} name={@icon} class="size-5 text-brand" />
          {@title}
        </h2>
        <.link
          :if={@see_more_path}
          href={@see_more_path}
          class="hidden sm:flex text-sm text-text-secondary hover:text-text-primary transition-colors items-center gap-1"
        >
          Ver mais <.icon name="hero-chevron-right" class="size-4" />
        </.link>
      </div>
      <%= if @type == :channels do %>
        <.carousel_arrows id={@carousel_id}>
          <div
            data-carousel-track
            class="grid grid-cols-3 gap-2 sm:grid-cols-none sm:grid-rows-2 sm:grid-flow-col sm:gap-4 sm:overflow-x-auto py-1 sm:py-2 scrollbar-hide scroll-smooth sm:auto-cols-[220px] lg:auto-cols-[280px]"
          >
            <.channel_card
              :for={{channel, idx} <- Enum.with_index(@items)}
              channel={channel}
              class={if idx >= 6, do: "hidden sm:block", else: ""}
            />
            <.see_more_card
              :if={@see_more_path}
              path={@see_more_path}
              type={@type}
              class="hidden sm:flex"
            />
          </div>
        </.carousel_arrows>
        <.link
          :if={@see_more_path && length(@items) > 6}
          href={@see_more_path}
          class="sm:hidden mt-3 flex items-center justify-center gap-2 py-2.5 text-sm text-text-secondary hover:text-text-primary bg-surface/50 rounded-lg transition-colors"
        >
          Ver todos os canais <.icon name="hero-arrow-right" class="size-4" />
        </.link>
      <% else %>
        <.carousel_arrows id={@carousel_id}>
          <div
            data-carousel-track
            class={[
              "grid grid-cols-3 gap-2 sm:flex sm:gap-4 sm:overflow-x-auto py-1 sm:py-2 scrollbar-hide scroll-smooth",
              @type in [:history] && "grid-cols-1 sm:grid-cols-none"
            ]}
          >
            <%= case @type do %>
              <% :movies -> %>
                <.render_movie_card
                  :for={{movie, idx} <- Enum.with_index(@items)}
                  movie={movie}
                  is_favorite={MapSet.member?(@favorites_map, movie.id)}
                  progress={Map.get(@progress_map, movie.id)}
                  class={if idx >= 6, do: "hidden sm:block", else: ""}
                />
              <% :series -> %>
                <.render_series_card
                  :for={{series, idx} <- Enum.with_index(@items)}
                  series={series}
                  is_favorite={MapSet.member?(@favorites_map, series.id)}
                  progress={Map.get(@progress_map, series.id)}
                  class={if idx >= 6, do: "hidden sm:block", else: ""}
                />
              <% :history -> %>
                <.history_item
                  :for={{entry, idx} <- Enum.with_index(@items)}
                  entry={entry}
                  class={if idx >= 3, do: "hidden sm:block", else: ""}
                />
              <% :favorites -> %>
                <.favorite_item
                  :for={{fav, idx} <- Enum.with_index(@items)}
                  favorite={fav}
                  class={if idx >= 6, do: "hidden sm:block", else: ""}
                />
            <% end %>
            <.see_more_card
              :if={@see_more_path}
              path={@see_more_path}
              type={@type}
              class="hidden sm:flex"
            />
          </div>
        </.carousel_arrows>
        <.link
          :if={@see_more_path && length(@items) > 6 && @type not in [:history]}
          href={@see_more_path}
          class="sm:hidden mt-3 flex items-center justify-center gap-2 py-2.5 text-sm text-text-secondary hover:text-text-primary bg-surface/50 rounded-lg transition-colors"
        >
          Ver mais <.icon name="hero-arrow-right" class="size-4" />
        </.link>
      <% end %>
    </div>
    """
  end

  def render_ai_trending_section(assigns) do
    assigns =
      assigns
      |> assign_new(:progress_map, fn -> %{} end)
      |> assign_new(:favorites_map, fn -> MapSet.new() end)

    ~H"""
    <div class="px-[4%]">
      <.section_header
        title="Em Alta Agora"
        icon="hero-fire-solid"
        icon_class="text-brand"
        genre_filters={@genre_filters}
        period_filters={@period_filters}
        selected_genre={@selected_genre}
        selected_period={@selected_period}
        on_genre_change="filter_trending_genre"
        on_period_change="filter_trending_period"
        see_more_path={~p"/browse/movies?sort=trending"}
        ai_powered={@ai_powered}
      />
      <.carousel_arrows id="carousel-trending">
        <div
          data-carousel-track
          class="grid grid-cols-3 gap-2 sm:flex sm:gap-4 sm:overflow-x-auto py-1 sm:py-2 scrollbar-hide scroll-smooth"
        >
          <.render_movie_card
            :for={{movie, idx} <- Enum.with_index(@items)}
            movie={movie}
            is_favorite={MapSet.member?(@favorites_map, movie.id)}
            progress={Map.get(@progress_map, movie.id)}
            class={if idx >= 6, do: "hidden sm:block", else: ""}
          />
          <.see_more_card
            path={~p"/browse/movies?sort=trending"}
            type={:movies}
            class="hidden sm:flex"
          />
        </div>
      </.carousel_arrows>
    </div>
    """
  end

  def render_ai_series_section(assigns) do
    assigns =
      assigns
      |> assign_new(:progress_map, fn -> %{} end)
      |> assign_new(:favorites_map, fn -> MapSet.new() end)

    ~H"""
    <div class="px-[4%]">
      <.section_header
        title="Séries Populares"
        icon="hero-tv-solid"
        icon_class="text-accent"
        genre_filters={@genre_filters}
        selected_genre={@selected_genre}
        on_genre_change="filter_series_genre"
        see_more_path={~p"/browse/series?sort=popularity"}
        ai_powered={@ai_powered}
      />
      <.carousel_arrows id="carousel-series">
        <div
          data-carousel-track
          class="grid grid-cols-3 gap-2 sm:flex sm:gap-4 sm:overflow-x-auto py-1 sm:py-2 scrollbar-hide scroll-smooth"
        >
          <.render_series_card
            :for={{series, idx} <- Enum.with_index(@items)}
            series={series}
            is_favorite={MapSet.member?(@favorites_map, series.id)}
            progress={Map.get(@progress_map, series.id)}
            class={if idx >= 6, do: "hidden sm:block", else: ""}
          />
          <.see_more_card
            path={~p"/browse/series?sort=popularity"}
            type={:series}
            class="hidden sm:flex"
          />
        </div>
      </.carousel_arrows>
    </div>
    """
  end

  def render_ai_channels_section(assigns) do
    ~H"""
    <div class="px-[4%]">
      <.section_header
        title="TV ao Vivo"
        icon="hero-signal-solid"
        icon_class="text-brand"
        genre_filters={@category_filters}
        selected_genre={@selected_category}
        on_genre_change="filter_channels_category"
        see_more_path={~p"/browse"}
        ai_powered={@ai_powered}
      />
      <.carousel_arrows id="carousel-channels">
        <div
          data-carousel-track
          class="grid grid-cols-3 gap-2 sm:grid-cols-none sm:grid-rows-2 sm:grid-flow-col sm:gap-4 sm:overflow-x-auto py-1 sm:py-2 scrollbar-hide scroll-smooth sm:auto-cols-[150px] lg:auto-cols-[176px] xl:auto-cols-[184px]"
        >
          <.channel_card
            :for={{channel, idx} <- Enum.with_index(@items)}
            channel={channel}
            class={if idx >= 6, do: "hidden sm:block", else: ""}
          />
          <.see_more_card path={~p"/browse"} type={:channels} class="hidden sm:flex" />
        </div>
      </.carousel_arrows>
    </div>
    """
  end

  def render_top_10(assigns) do
    ~H"""
    <div class="px-[4%]">
      <div class="flex items-center justify-between mb-3 sm:mb-4">
        <h2 class="text-base sm:text-xl font-semibold text-text-primary flex items-center gap-2">
          <.icon name="hero-trophy" class="size-5 text-warning" />
          {@title}
        </h2>
        <.link
          href={~p"/browse/movies?sort=rating"}
          class="hidden sm:flex text-sm text-text-secondary hover:text-text-primary transition-colors items-center gap-1"
        >
          Ver mais <.icon name="hero-chevron-right" class="size-4" />
        </.link>
      </div>
      <.carousel_arrows id="carousel-top10">
        <div
          data-carousel-track
          class="flex gap-3 sm:gap-4 overflow-x-auto py-1 sm:py-2 scrollbar-hide scroll-smooth"
        >
          <.top_10_card
            :for={{movie, index} <- Enum.with_index(@items, 1)}
            movie={movie}
            rank={index}
          />
        </div>
      </.carousel_arrows>
    </div>
    """
  end

  def top_10_card(assigns) do
    ~H"""
    <.link
      href={~p"/browse/movies/#{@movie.id}"}
      class="group flex-shrink-0 relative"
    >
      <div class="flex items-end">
        <div class="relative z-10 -mr-4 sm:-mr-6">
          <span class={[
            "text-[80px] sm:text-[120px] font-black leading-none",
            "bg-gradient-to-b from-text-primary to-text-muted bg-clip-text text-transparent",
            "drop-shadow-[0_2px_2px_rgba(0,0,0,0.8)]",
            @rank == 1 && "from-warning to-brand",
            @rank == 2 && "from-gray-300 to-gray-500",
            @rank == 3 && "from-warning/80 to-brand/80"
          ]}>
            {@rank}
          </span>
        </div>
        <div class="w-[100px] sm:w-[140px] rounded-lg overflow-hidden bg-surface-hover shadow-card transition-all group-hover:-translate-y-1 group-hover:shadow-card-hover">
          <div class="aspect-[2/3] relative">
            <div id={"top10-img-#{@movie.id}"} phx-hook="ImageFallback" class="w-full h-full">
              <img
                :if={@movie.stream_icon}
                src={ImageProxy.proxy(@movie.stream_icon)}
                alt={@movie.name}
                class="w-full h-full object-cover transition-transform duration-300"
                loading="lazy"
                data-fallback-target
              />
              <div
                data-fallback
                class={[
                  "w-full h-full flex flex-col items-center justify-center bg-gradient-to-br from-zinc-800 to-zinc-900 p-2 text-center",
                  @movie.stream_icon && "hidden"
                ]}
              >
                <.icon name="hero-film" class="size-6 text-brand/60 mb-1" />
                <span class="text-2xs text-text-muted leading-tight line-clamp-2">
                  {@movie.name}
                </span>
              </div>
            </div>
            <div class="absolute inset-0 bg-black/30 opacity-0 group-hover:opacity-100 transition-opacity duration-200 hidden sm:flex items-center justify-center">
              <.icon name="hero-play-circle-solid" class="size-10 text-white/90 drop-shadow-lg" />
            </div>
            <div
              :if={@movie.rating}
              class="absolute top-1 right-1 flex items-center gap-0.5 px-1 py-0.5 bg-black/70 rounded text-2xs text-white"
            >
              <.icon name="hero-star-solid" class="size-2.5 text-warning" />
              {Float.round(Decimal.to_float(@movie.rating), 1)}
            </div>
          </div>
        </div>
      </div>
    </.link>
    """
  end

  def see_more_card(assigns) do
    assigns = assign_new(assigns, :class, fn -> nil end)

    card_class =
      case assigns.type do
        :channels -> "aspect-video w-[150px] lg:w-[176px]"
        :history -> "aspect-video w-[220px] lg:w-[240px]"
        :favorites -> "aspect-[2/3] w-[96px] lg:w-[108px]"
        _ -> "aspect-[2/3] w-[132px] lg:w-[148px]"
      end

    assigns = assign(assigns, :card_class, card_class)

    ~H"""
    <.link
      href={@path}
      class={[
        "group flex-shrink-0 rounded-lg overflow-hidden bg-surface/50 border border-white/10",
        "hover:bg-surface hover:border-white/20 transition-all duration-200",
        "flex items-center justify-center",
        @card_class,
        @class
      ]}
    >
      <div class="text-center p-4">
        <div class="w-12 h-12 mx-auto mb-2 rounded-full bg-surface-hover group-hover:bg-surface flex items-center justify-center transition-colors">
          <.icon
            name="hero-arrow-right"
            class="size-6 text-text-secondary group-hover:text-text-primary transition-colors"
          />
        </div>
        <span class="text-sm text-text-secondary group-hover:text-text-primary transition-colors">
          Ver mais
        </span>
      </div>
    </.link>
    """
  end
end
