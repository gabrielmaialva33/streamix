defmodule StreamixWeb.Content.DetailComponents do
  @moduledoc """
  Detail and modal components shared across movie / series / episode pages.

  > **TODO (planned split):** this module is ~900 lines and 26 public
  > components. The shape we want to land on, when the refactor budget
  > allows, is:
  >
  >   * `detail_components/badges.ex` — `rating_badge`, `content_rating_badge`,
  >     `year_badge`, `duration_badge`, `date_badge`, `extension_badge`,
  >     `series_count_badge`
  >   * `detail_components/actions.ex` — `play_button`, `favorite_button`,
  >     `trailer_link`, `tmdb_link`
  >   * `detail_components/modals.ex` — `gallery_preview`, `image_gallery`,
  >     `content_detail_modal`, `season_accordion`, `detail_season_accordion`
  >   * `detail_components.ex` (top) — keeps the layout primitives
  >     (`detail_hero`, `detail_title`, `genre_chips`, `synopsis_section`,
  >     `credits_grid`, `similar_grid`, `detail_episode_item`,
  >     `episode_navigation`) plus the `detail_format_duration/1` helper.
  >
  > The split changes the import surface (LiveViews currently do
  > `import StreamixWeb.Content.DetailComponents`), so it's deliberately
  > batched into its own PR — not done in this round because the call
  > sites are spread across all detail LiveViews + tests and the win is
  > stylistic, not load-bearing.
  """
  use Phoenix.Component
  use StreamixWeb, :verified_routes
  import StreamixWeb.CoreComponents
  # Shared helpers and internal formats
  import StreamixWeb.Content.CardComponents
  import StreamixWeb.Content.HelperComponents
  alias StreamixWeb.Helpers.ImageProxy

  @doc """
  Renders a compact gallery image preview.
  """
  attr :image, :string, default: nil
  attr :alt, :string, default: "Imagem da galeria"

  def gallery_preview(assigns) do
    ~H"""
    <div
      :if={@image}
      class="fixed inset-0 z-50 flex items-center justify-center px-4 py-8"
      phx-window-keydown="close_gallery_preview"
      phx-key="Escape"
    >
      <button
        type="button"
        class="absolute inset-0 bg-black/70 backdrop-blur-sm"
        phx-click="close_gallery_preview"
        aria-label="Fechar imagem"
      />

      <figure class="relative z-10 w-full max-w-5xl overflow-hidden rounded-lg border border-border bg-surface shadow-modal">
        <button
          type="button"
          phx-click="close_gallery_preview"
          class="absolute right-3 top-3 z-10 inline-flex size-9 items-center justify-center rounded-lg bg-black/60 text-white transition-colors hover:bg-black/80 focus:outline-none focus:ring-2 focus:ring-brand"
          aria-label="Fechar imagem"
        >
          <.icon name="hero-x-mark" class="size-5" />
        </button>
        <img
          src={@image}
          alt={@alt}
          class="max-h-[82dvh] w-full object-contain bg-black"
          loading="eager"
          decoding="async"
        />
      </figure>
    </div>
    """
  end

  @doc """
  Renders a season accordion with episodes.

  ## Attributes

    * `:season` - The season struct/map with episodes
    * `:expanded` - Whether the accordion is expanded
    * `:on_toggle` - Event name for toggle action
    * `:on_play_episode` - Event name for episode play

  ## Examples

      <.season_accordion season={season} expanded={false} />
  """
  attr :season, :map, required: true
  attr :expanded, :boolean, default: false
  attr :on_toggle, :string, default: "toggle_season"
  attr :on_play_episode, :string, default: "play_episode"

  def season_accordion(assigns) do
    ~H"""
    <details class="bg-surface rounded-lg group" open={@expanded}>
      <summary
        class="flex items-center justify-between gap-3 px-4 py-3 cursor-pointer hover:bg-surface-hover rounded-lg transition-colors list-none"
        phx-click={@on_toggle}
        phx-value-id={@season.id}
      >
        <div class="flex items-center gap-3">
          <span class="font-medium text-text-primary">
            Temporada {Map.get(@season, :season_number) || Map.get(@season, :num) || "?"}
          </span>
          <span
            :if={Map.get(@season, :episodes)}
            class="px-2 py-0.5 text-xs rounded bg-surface-hover text-text-secondary"
          >
            {length(@season.episodes)} episódios
          </span>
        </div>
        <.icon
          name="hero-chevron-down"
          class="size-5 text-text-secondary transition-transform group-open:rotate-180"
        />
      </summary>
      <div class="px-4 pb-4 space-y-2">
        <.episode_card
          :for={episode <- Map.get(@season, :episodes) || []}
          episode={episode}
          on_play={@on_play_episode}
        />
      </div>
    </details>
    """
  end

  @doc """
  Renders a movie/series detail modal.

  ## Attributes

    * `:content` - The content to display
    * `:type` - Type of content (:movie or :series)
    * `:on_play` - Event name for play action
    * `:on_close` - Event name for closing the modal

  ## Examples

      <.content_detail_modal content={@movie} type={:movie} />
  """
  attr :content, :map, required: true
  attr :type, :atom, required: true, values: [:movie, :series]
  attr :on_play, :string, default: "play"
  attr :on_close, :string, default: "close_detail"

  def content_detail_modal(assigns) do
    ~H"""
    <div
      class="fixed inset-0 z-50 flex items-center justify-center p-4 bg-black/80"
      phx-click-away={@on_close}
    >
      <div class="bg-surface rounded-lg overflow-hidden max-w-3xl w-full shadow-2xl">
        <div class="relative h-64 bg-surface-hover">
          <img
            :if={Map.get(@content, :backdrop) || Map.get(@content, :cover)}
            src={Map.get(@content, :backdrop) || Map.get(@content, :cover)}
            alt={@content.name}
            class="w-full h-full object-cover"
            fetchpriority="high"
            decoding="async"
          />
          <div class="absolute inset-0 bg-gradient-to-t from-surface to-transparent" />

          <button
            type="button"
            phx-click={@on_close}
            class="absolute top-4 right-4 p-2 rounded-full bg-black/50 text-white hover:bg-black/70 transition-colors"
          >
            <.icon name="hero-x-mark" class="size-5" />
          </button>

          <div class="absolute bottom-4 left-6 right-6">
            <h2 class="text-2xl font-bold text-white">
              {Map.get(@content, :title) || @content.name}
            </h2>
          </div>
        </div>

        <div class="p-6 space-y-4">
          <div class="flex items-center gap-4 text-sm text-text-secondary">
            <span :if={Map.get(@content, :year)}>{@content.year}</span>
            <span :if={Map.get(@content, :rating)} class="flex items-center gap-1">
              <.icon name="hero-star-solid" class="size-4 text-warning" />
              {format_rating(@content.rating)}
            </span>
            <span :if={Map.get(@content, :genres, []) != []}>{format_genre_names(@content)}</span>
            <span :if={Map.get(@content, :duration_secs)}>
              {format_duration(@content.duration_secs)}
            </span>
          </div>

          <p :if={Map.get(@content, :plot)} class="text-text-secondary">
            {@content.plot}
          </p>

          <div class="flex items-center gap-3 pt-4">
            <button
              type="button"
              phx-click={@on_play}
              phx-value-id={@content.id}
              class="inline-flex items-center gap-2 px-6 py-3 bg-brand text-white font-semibold rounded-md hover:bg-brand-hover transition-colors"
            >
              <.icon name="hero-play-solid" class="size-5" /> Assistir
            </button>
          </div>
        </div>
      </div>
    </div>
    """
  end

  attr :id, :string, default: nil
  attr :image, :string, default: nil
  attr :alt, :string, required: true
  attr :back_path, :string, required: true
  attr :height_class, :string, default: "h-[30vh] sm:h-[50vh] lg:h-[60vh]"
  attr :min_height_class, :string, default: "min-h-[200px] sm:min-h-[400px]"
  attr :fallback_hook?, :boolean, default: false
  attr :compact_back?, :boolean, default: false

  def detail_hero(assigns) do
    ~H"""
    <div class={["relative", @height_class, @min_height_class]}>
      <div
        id={@id}
        phx-hook={@fallback_hook? && "ImageFallback"}
        class="absolute inset-0"
      >
        <img
          :if={@image}
          src={@image}
          alt={@alt}
          class="w-full h-full object-cover"
          data-fallback-target={@fallback_hook?}
          fetchpriority="high"
          decoding="async"
        />
        <div
          :if={@fallback_hook? || !@image}
          data-fallback={@fallback_hook?}
          class={[
            "w-full h-full bg-gradient-to-br from-neutral-800 to-neutral-900",
            @fallback_hook? && @image && "hidden"
          ]}
        />
      </div>

      <div class="absolute inset-0 bg-gradient-to-t from-background via-background/60 to-transparent" />
      <div class="absolute inset-0 bg-gradient-to-r from-background via-background/30 to-transparent" />

      <div class="absolute top-4 left-4 sm:top-6 sm:left-6 z-10">
        <.link
          href={@back_path}
          class={[
            "inline-flex items-center gap-1.5 sm:gap-2 px-3 sm:px-4 py-1.5 sm:py-2 bg-black/40 backdrop-blur-sm text-white/90 hover:text-white hover:bg-black/60 rounded-full transition-all text-xs sm:text-sm font-medium",
            "min-h-11",
            @compact_back? && "max-w-[200px] sm:max-w-none"
          ]}
        >
          <.icon
            name="hero-arrow-left"
            class={["size-3.5 sm:size-4", @compact_back? && "flex-shrink-0"]}
          />
          <span class={@compact_back? && "truncate"}>Voltar</span>
        </.link>
      </div>
    </div>
    """
  end

  attr :title, :string, required: true
  attr :subtitle, :string, default: nil
  attr :tagline, :string, default: nil

  def detail_title(assigns) do
    ~H"""
    <div class="space-y-1 sm:space-y-2">
      <h1 class="text-lg sm:text-3xl lg:text-5xl font-bold text-text-primary leading-tight">
        {@title}
      </h1>
      <p :if={@subtitle} class="text-sm sm:text-lg text-text-secondary">
        {@subtitle}
      </p>
      <p :if={present?(@tagline)} class="text-sm sm:text-lg italic text-text-secondary/80">
        "{@tagline}"
      </p>
    </div>
    """
  end

  attr :rating, :any, default: nil
  attr :class, :any, default: nil
  attr :divide_by_two?, :boolean, default: true

  def rating_badge(assigns) do
    assigns =
      assign(
        assigns,
        :display_rating,
        detail_format_rating(assigns.rating, assigns.divide_by_two?)
      )

    ~H"""
    <span
      :if={@display_rating}
      class={[
        "inline-flex items-center gap-1 h-6 sm:h-8 px-2 sm:px-2.5 bg-warning/10 text-warning rounded-md text-xs sm:text-sm font-semibold",
        @class
      ]}
    >
      <.icon name="hero-star-solid" class="size-3 sm:size-3.5" />
      {@display_rating}
    </span>
    """
  end

  attr :rating, :string, default: nil

  def content_rating_badge(assigns) do
    ~H"""
    <span
      :if={@rating}
      class={[
        "inline-flex items-center justify-center min-w-[36px] sm:min-w-[42px] h-6 sm:h-8 px-2 sm:px-2.5 rounded-md text-[10px] sm:text-xs font-bold",
        content_rating_class(@rating)
      ]}
      title="Classificação Indicativa"
    >
      {@rating}
    </span>
    """
  end

  attr :year, :any, default: nil

  def year_badge(assigns) do
    ~H"""
    <span
      :if={@year}
      class="inline-flex items-center h-6 sm:h-8 px-2 sm:px-2.5 bg-surface text-text-primary rounded-md text-xs sm:text-sm font-medium"
    >
      {@year}
    </span>
    """
  end

  attr :seconds, :integer, default: nil

  def duration_badge(assigns) do
    assigns = assign(assigns, :duration, detail_format_duration(assigns.seconds))

    ~H"""
    <span
      :if={@duration}
      class="inline-flex items-center gap-1 h-6 sm:h-8 px-2 sm:px-2.5 bg-surface text-text-secondary rounded-md text-xs sm:text-sm"
    >
      <.icon name="hero-clock" class="size-3 sm:size-3.5" />{@duration}
    </span>
    """
  end

  attr :date, :any, default: nil

  def date_badge(assigns) do
    assigns = assign(assigns, :formatted_date, detail_format_date(assigns.date))

    ~H"""
    <span
      :if={@formatted_date}
      class="inline-flex items-center gap-1 h-6 sm:h-8 px-2 sm:px-2.5 bg-surface text-text-secondary rounded-md text-xs sm:text-sm"
    >
      <.icon name="hero-calendar" class="size-3 sm:size-3.5" />{@formatted_date}
    </span>
    """
  end

  attr :extension, :string, default: nil

  def extension_badge(assigns) do
    ~H"""
    <span
      :if={@extension}
      class="inline-flex items-center h-6 sm:h-8 px-2 sm:px-2.5 bg-brand/20 text-brand rounded-md uppercase text-[10px] sm:text-xs font-bold"
    >
      {@extension}
    </span>
    """
  end

  attr :seasons, :list, default: []

  def series_count_badge(assigns) do
    assigns = assign(assigns, :episode_count, count_episodes(assigns.seasons))

    ~H"""
    <span class="inline-flex items-center gap-1 h-6 sm:h-8 px-2 sm:px-2.5 bg-surface text-text-secondary rounded-md text-xs sm:text-sm">
      <.icon name="hero-tv" class="size-3 sm:size-3.5" />
      {length(@seasons)} temp · {@episode_count} eps
    </span>
    """
  end

  attr :genres, :list, default: []

  def genre_chips(assigns) do
    ~H"""
    <div
      :if={@genres != []}
      class="flex flex-wrap items-center justify-center lg:justify-start gap-1.5 sm:gap-2"
    >
      <span
        :for={genre <- @genres}
        class="px-2 sm:px-3 py-0.5 sm:py-1 bg-white/5 text-text-secondary rounded-full text-xs sm:text-sm border border-white/10 hover:border-white/20 transition-colors"
      >
        {genre.name}
      </span>
    </div>
    """
  end

  attr :event, :string, required: true
  attr :label, :string, required: true

  def play_button(assigns) do
    ~H"""
    <button
      type="button"
      phx-click={@event}
      class="inline-flex min-h-11 items-center justify-center gap-1.5 w-full sm:w-auto px-4 sm:px-8 py-2.5 sm:py-3.5 bg-brand text-white font-bold rounded-lg hover:bg-brand-hover transition-colors shadow-card text-xs sm:text-base focus:outline-none focus:ring-2 focus:ring-brand focus:ring-offset-2 focus:ring-offset-background"
    >
      <.icon name="hero-play-solid" class="size-4 sm:size-5" /> {@label}
    </button>
    """
  end

  attr :favorite?, :boolean, default: false
  attr :label_on, :string, default: "Remover dos favoritos"
  attr :label_off, :string, default: "Adicionar aos favoritos"

  def favorite_button(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="toggle_favorite"
      class={[
        "inline-flex items-center justify-center w-10 h-10 sm:w-12 sm:h-12 rounded-lg border-2 transition-all focus:outline-none focus:ring-2 focus:ring-brand",
        @favorite? && "bg-brand border-brand text-white",
        !@favorite? &&
          "border-border text-text-secondary hover:border-text-secondary hover:text-text-primary bg-surface"
      ]}
      aria-label={if @favorite?, do: @label_on, else: @label_off}
    >
      <.icon
        name={if @favorite?, do: "hero-heart-solid", else: "hero-heart"}
        class="size-4 sm:size-5"
      />
    </button>
    """
  end

  attr :youtube_id, :string, default: nil

  def trailer_link(assigns) do
    assigns = assign(assigns, :url, trailer_url(assigns.youtube_id))

    ~H"""
    <a
      :if={@url}
      href={@url}
      target="_blank"
      rel="noopener noreferrer"
      class="inline-flex min-h-11 items-center gap-1.5 sm:gap-2 px-3 sm:px-5 py-2.5 sm:py-3 bg-surface border border-border text-text-primary font-semibold rounded-lg hover:bg-surface-hover transition-colors text-sm"
    >
      <.icon name="hero-play-circle" class="size-4 sm:size-5 text-brand" /> Trailer
    </a>
    """
  end

  attr :tmdb_id, :any, default: nil
  attr :type, :string, required: true, values: ["movie", "tv"]

  def tmdb_link(assigns) do
    ~H"""
    <a
      :if={@tmdb_id}
      href={"https://www.themoviedb.org/#{@type}/#{@tmdb_id}"}
      target="_blank"
      rel="noopener noreferrer"
      class="inline-flex min-h-11 items-center gap-1.5 sm:gap-2 px-3 sm:px-4 py-2.5 sm:py-3 bg-surface border border-border text-text-secondary rounded-lg hover:text-text-primary hover:bg-surface-hover transition-colors text-xs sm:text-sm"
      title="Ver no The Movie Database"
    >
      <svg class="size-3.5 sm:size-4" viewBox="0 0 24 24" fill="currentColor">
        <path d="M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm-1 17.93c-3.95-.49-7-3.85-7-7.93 0-.62.08-1.21.21-1.79L9 15v1c0 1.1.9 2 2 2v1.93zm6.9-2.54c-.26-.81-1-1.39-1.9-1.39h-1v-3c0-.55-.45-1-1-1H8v-2h2c.55 0 1-.45 1-1V7h2c1.1 0 2-.9 2-2v-.41c2.93 1.19 5 4.06 5 7.41 0 2.08-.8 3.97-2.1 5.39z" />
      </svg>
      TMDB
    </a>
    """
  end

  attr :title, :string, default: "Sinopse"
  attr :text, :string, default: nil
  attr :class, :any, default: nil

  def synopsis_section(assigns) do
    ~H"""
    <div :if={present?(@text)} class="pt-2 sm:pt-4">
      <h3 class="text-base sm:text-lg font-semibold text-text-primary mb-2 sm:mb-3">
        {@title}
      </h3>
      <p class={["text-text-secondary text-sm sm:text-base leading-relaxed", @class]}>
        {@text}
      </p>
    </div>
    """
  end

  attr :content, :map, required: true
  attr :director_label, :string, default: "Direção"

  def credits_grid(assigns) do
    assigns =
      assigns
      |> assign(:directors, director_names(assigns.content))
      |> assign(:cast, cast_names(assigns.content))

    ~H"""
    <div
      :if={@directors != "" or @cast != ""}
      class="grid sm:grid-cols-2 gap-4 sm:gap-6 pt-2 sm:pt-4"
    >
      <div :if={@directors != ""} class="space-y-1 sm:space-y-2">
        <h4 class="text-xs sm:text-sm font-semibold text-text-secondary uppercase tracking-wide">
          {@director_label}
        </h4>
        <p class="text-text-primary text-sm sm:text-base">{@directors}</p>
      </div>

      <div :if={@cast != ""} class="space-y-1 sm:space-y-2">
        <h4 class="text-xs sm:text-sm font-semibold text-text-secondary uppercase tracking-wide">
          Elenco
        </h4>
        <p class="text-text-primary text-sm sm:text-base">
          {truncate_cast(@cast)}
        </p>
      </div>
    </div>
    """
  end

  attr :images, :list, default: []
  attr :title, :string, default: "Galeria"
  attr :alt, :string, default: "Imagem da galeria"

  def image_gallery(assigns) do
    ~H"""
    <div :if={@images != []} class="mt-8 sm:mt-12">
      <h3 class="text-lg sm:text-xl font-semibold text-text-primary mb-3 sm:mb-4">{@title}</h3>
      <div class="responsive-gallery-grid">
        <button
          :for={image <- @images}
          type="button"
          phx-click="open_gallery_image"
          phx-value-src={image}
          class="aspect-video rounded-lg overflow-hidden bg-surface-hover cursor-pointer hover:ring-2 hover:ring-brand transition-all group focus:outline-none focus:ring-2 focus:ring-brand"
          aria-label="Abrir imagem da galeria"
        >
          <img
            src={image}
            alt={@alt}
            class="w-full h-full object-cover group-hover:scale-105 transition-transform duration-300"
            loading="lazy"
            decoding="async"
          />
        </button>
      </div>
    </div>
    """
  end

  attr :items, :list, default: []
  attr :kind, :atom, required: true, values: [:movie, :series]
  attr :mode, :atom, required: true
  attr :provider, :map, required: true
  attr :return_to, :string, default: nil
  attr :title, :string, required: true

  def similar_grid(assigns) do
    ~H"""
    <div :if={@items != []} class="mt-8 sm:mt-12">
      <h3 class="text-lg sm:text-xl font-semibold text-text-primary mb-3 sm:mb-4">
        {@title}
      </h3>
      <div class="grid grid-cols-3 sm:grid-cols-3 lg:grid-cols-4 xl:grid-cols-6 gap-2 sm:gap-4">
        <.link
          :for={item <- @items}
          navigate={with_return_to(similar_path(@kind, @mode, @provider, item), @return_to)}
          class="group block transition-all duration-300"
        >
          <div
            id={@kind == :movie && "similar-img-#{item.id}"}
            phx-hook={@kind == :movie && "ImageFallback"}
            class="aspect-[2/3] bg-surface-hover relative rounded-md sm:rounded-lg overflow-hidden shadow-sm group-hover:shadow-xl group-hover:shadow-brand/20 transition-all duration-300 group-hover:-translate-y-1 block"
          >
            <img
              :if={poster_image(@kind, item)}
              src={poster_image(@kind, item)}
              alt={display_title(item)}
              class="w-full h-full object-cover transition-transform duration-300"
              loading="lazy"
              decoding="async"
              data-fallback-target={@kind == :movie}
            />
            <div
              :if={@kind == :series || !poster_image(@kind, item)}
              data-fallback={@kind == :movie}
              class={[
                fallback_class(@kind),
                @kind == :movie && poster_image(@kind, item) && "hidden"
              ]}
            >
              <.icon name={fallback_icon(@kind)} class={fallback_icon_class(@kind)} />
              <span
                :if={@kind == :movie}
                class="text-[9px] text-text-muted leading-tight line-clamp-2"
              >
                {display_title(item)}
              </span>
            </div>
          </div>
          <div class="px-0.5 pt-1.5 sm:pt-2">
            <p class="text-[11px] sm:text-sm text-text-primary font-medium truncate group-hover:text-brand transition-colors mt-0.5">
              {display_title(item)}
            </p>
            <p :if={item.year} class="text-[10px] sm:text-xs text-text-secondary">
              {item.year}
            </p>
          </div>
        </.link>
      </div>
    </div>
    """
  end

  attr :season, :map, required: true
  attr :expanded, :boolean, default: false

  def detail_season_accordion(assigns) do
    episodes = Enum.sort_by(assigns.season.episodes || [], & &1.episode_num)
    assigns = assign(assigns, :episodes, episodes)

    ~H"""
    <div class="bg-surface rounded-lg sm:rounded-xl overflow-hidden border border-border">
      <button
        type="button"
        phx-click="toggle_season"
        phx-value-id={@season.id}
        class="w-full flex items-center justify-between px-4 sm:px-6 py-3 sm:py-4 hover:bg-surface-hover transition-colors"
      >
        <div class="flex items-center gap-2 sm:gap-4">
          <span class="text-base sm:text-lg font-semibold text-text-primary">
            Temporada {@season.season_number}
          </span>
          <span class="text-xs sm:text-sm text-text-secondary">{length(@episodes)} eps</span>
        </div>
        <.icon
          name="hero-chevron-down"
          class={[
            "size-4 sm:size-5 text-text-secondary transition-transform duration-200",
            @expanded && "rotate-180"
          ]}
        />
      </button>

      <div :if={@expanded} class="border-t border-border">
        <div class="divide-y divide-border">
          <.detail_episode_item :for={episode <- @episodes} episode={episode} />
        </div>
      </div>
    </div>
    """
  end

  attr :episode, :map, required: true

  def detail_episode_item(assigns) do
    ~H"""
    <div
      class="flex gap-2 sm:gap-4 p-3 sm:p-4 hover:bg-surface-hover cursor-pointer transition-colors group"
      phx-click="view_episode"
      phx-value-id={@episode.id}
    >
      <div class="flex-shrink-0 w-6 sm:w-8 text-center">
        <span class="text-lg sm:text-2xl font-bold text-text-secondary/30">
          {@episode.episode_num}
        </span>
      </div>

      <div class="relative flex-shrink-0 w-24 sm:w-36 aspect-video bg-surface-hover rounded-lg overflow-hidden">
        <img
          :if={@episode.cover}
          src={ImageProxy.proxy(@episode.cover)}
          alt={episode_item_title(@episode)}
          class="w-full h-full object-cover"
          loading="lazy"
          decoding="async"
        />
        <div
          :if={!@episode.cover}
          class="w-full h-full flex items-center justify-center bg-surface"
        >
          <.icon name="hero-play-circle" class="size-6 sm:size-10 text-text-secondary/30" />
        </div>

        <div class="absolute inset-0 bg-black/50 opacity-0 group-hover:opacity-100 transition-opacity flex items-center justify-center">
          <div class="w-8 h-8 sm:w-10 sm:h-10 rounded-full bg-white flex items-center justify-center">
            <.icon name="hero-play-solid" class="size-4 sm:size-5 text-black ml-0.5" />
          </div>
        </div>
      </div>

      <div class="flex-1 min-w-0">
        <h4 class="font-medium text-sm sm:text-base text-text-primary group-hover:text-brand truncate">
          {episode_item_title(@episode)}
        </h4>
        <p
          :if={@episode.plot}
          class="text-xs sm:text-sm text-text-secondary line-clamp-2 mt-0.5 sm:mt-1 hidden sm:block"
        >
          {@episode.plot}
        </p>
        <span
          :if={@episode.duration_secs}
          class="text-[10px] sm:text-xs text-text-secondary/60 mt-1 sm:mt-2 block"
        >
          {detail_format_duration(@episode.duration_secs)}
        </span>
      </div>
    </div>
    """
  end

  attr :mode, :atom, required: true
  attr :provider, :map, required: true
  attr :series, :map, required: true
  attr :prev_episode, :map, default: nil
  attr :next_episode, :map, default: nil

  def episode_navigation(assigns) do
    ~H"""
    <div class="mt-6 sm:mt-10 pt-6 sm:pt-8 border-t border-border">
      <div class="flex items-center justify-between gap-2 sm:gap-4">
        <div class="flex-1 min-w-0">
          <.link
            :if={@prev_episode}
            navigate={episode_path(@mode, @provider, @series.id, @prev_episode.id)}
            class="inline-flex items-center gap-2 sm:gap-3 p-2.5 sm:p-4 rounded-lg sm:rounded-xl bg-surface hover:bg-surface-hover transition-colors group"
          >
            <.icon
              name="hero-chevron-left"
              class="size-4 sm:size-5 text-text-secondary group-hover:text-text-primary flex-shrink-0"
            />
            <div class="text-left min-w-0">
              <p class="text-[10px] sm:text-xs text-text-secondary uppercase tracking-wide">
                Anterior
              </p>
              <p class="text-xs sm:text-sm font-medium text-text-primary truncate">
                Ep. {@prev_episode.episode_num}
              </p>
            </div>
          </.link>
        </div>

        <.link
          navigate={series_path(@mode, @provider, @series.id)}
          class="hidden sm:inline-flex items-center gap-2 px-4 sm:px-5 py-2.5 sm:py-3 bg-surface border border-border text-text-secondary rounded-lg hover:text-text-primary hover:bg-surface-hover transition-colors text-xs sm:text-sm"
        >
          <.icon name="hero-list-bullet" class="size-4" /> Todos os Episódios
        </.link>

        <div class="flex-1 flex justify-end min-w-0">
          <.link
            :if={@next_episode}
            navigate={episode_path(@mode, @provider, @series.id, @next_episode.id)}
            class="inline-flex items-center gap-2 sm:gap-3 p-2.5 sm:p-4 rounded-lg sm:rounded-xl bg-surface hover:bg-surface-hover transition-colors group"
          >
            <div class="text-right min-w-0">
              <p class="text-[10px] sm:text-xs text-text-secondary uppercase tracking-wide">
                Próximo
              </p>
              <p class="text-xs sm:text-sm font-medium text-text-primary truncate">
                Ep. {@next_episode.episode_num}
              </p>
            </div>
            <.icon
              name="hero-chevron-right"
              class="size-4 sm:size-5 text-text-secondary group-hover:text-text-primary flex-shrink-0"
            />
          </.link>
        </div>
      </div>
    </div>
    """
  end

  def detail_format_duration(seconds) when is_integer(seconds) and seconds > 0 do
    total_minutes = div(seconds, 60)
    hours = div(total_minutes, 60)
    mins = rem(total_minutes, 60)

    cond do
      hours > 0 and mins > 0 -> "#{hours}h #{mins}min"
      hours > 0 -> "#{hours}h"
      true -> "#{mins}min"
    end
  end

  def detail_format_duration(_), do: nil

  defp detail_format_rating(nil, _divide_by_two?), do: nil

  defp detail_format_rating(%Decimal{} = rating, true) do
    rating
    |> Decimal.div(2)
    |> Decimal.round(1)
    |> Decimal.to_string()
  end

  defp detail_format_rating(%Decimal{} = rating, false) do
    rating
    |> Decimal.to_float()
    |> :erlang.float_to_binary(decimals: 1)
  end

  defp detail_format_rating(rating, true) when is_number(rating) do
    Float.round(rating / 2, 1) |> to_string()
  end

  defp detail_format_rating(rating, false) when is_number(rating) do
    :erlang.float_to_binary(rating * 1.0, decimals: 1)
  end

  defp detail_format_rating(_, _divide_by_two?), do: nil

  defp detail_format_date(nil), do: nil
  defp detail_format_date(date), do: Calendar.strftime(date, "%d/%m/%Y")

  defp content_rating_class(rating) when is_binary(rating) do
    case String.upcase(rating) do
      value when value in ["L", "G", "TV-G", "TV-Y", "TV-Y7"] -> "bg-success/10 text-success"
      value when value in ["10", "PG", "TV-PG"] -> "bg-info/10 text-info"
      value when value in ["12", "PG-13", "TV-14"] -> "bg-warning/10 text-warning"
      "14" -> "bg-warning/15 text-warning"
      value when value in ["16", "R", "TV-MA"] -> "bg-error/10 text-error"
      value when value in ["18", "NC-17"] -> "bg-error/15 text-error"
      _ -> "bg-surface text-text-secondary"
    end
  end

  defp content_rating_class(_), do: "bg-surface text-text-secondary"

  defp trailer_url(youtube_id) when is_binary(youtube_id) do
    if String.contains?(youtube_id, "youtube.com") or String.contains?(youtube_id, "youtu.be") do
      youtube_id
    else
      "https://www.youtube.com/watch?v=#{youtube_id}"
    end
  end

  defp trailer_url(_), do: nil

  defp director_names(%{credits: credits}) when is_list(credits) do
    credits
    |> Enum.filter(&(&1.role == "director"))
    |> Enum.map_join(", ", & &1.person.name)
  end

  defp director_names(_), do: ""

  defp cast_names(%{credits: credits}) when is_list(credits) do
    credits
    |> Enum.filter(&(&1.role == "cast"))
    |> Enum.sort_by(& &1.position)
    |> Enum.map_join(", ", & &1.person.name)
  end

  defp cast_names(_), do: ""

  defp truncate_cast(str) when is_binary(str) do
    str
    |> String.split(",")
    |> Enum.take(5)
    |> Enum.map_join(", ", &String.trim/1)
  end

  defp truncate_cast(_), do: ""

  defp count_episodes(seasons) do
    Enum.sum(Enum.map(seasons, fn season -> length(season.episodes || []) end))
  end

  defp present?(value), do: is_binary(value) and value != ""

  defp display_title(item), do: item.title || item.name

  defp poster_image(:movie, item), do: item.stream_icon && ImageProxy.proxy(item.stream_icon)
  defp poster_image(:series, item), do: item.cover && ImageProxy.proxy(item.cover)

  defp similar_path(:movie, :browse, _provider, movie), do: ~p"/browse/movies/#{movie.id}"

  defp similar_path(:movie, :provider, provider, movie),
    do: ~p"/providers/#{provider.id}/movies/#{movie.id}"

  defp similar_path(:series, :browse, _provider, series), do: ~p"/browse/series/#{series.id}"

  defp similar_path(:series, :provider, provider, series),
    do: ~p"/providers/#{provider.id}/series/#{series.id}"

  defp with_return_to(path, return_to) when is_binary(return_to) do
    separator = if String.contains?(path, "?"), do: "&", else: "?"
    path <> separator <> "return_to=" <> URI.encode_www_form(return_to)
  end

  defp with_return_to(path, _return_to), do: path

  defp series_path(:browse, _provider, series_id), do: ~p"/browse/series/#{series_id}"

  defp series_path(:provider, provider, series_id),
    do: ~p"/providers/#{provider.id}/series/#{series_id}"

  defp episode_path(:browse, _provider, series_id, episode_id),
    do: ~p"/browse/series/#{series_id}/episode/#{episode_id}"

  defp episode_path(:provider, provider, series_id, episode_id),
    do: ~p"/providers/#{provider.id}/series/#{series_id}/episode/#{episode_id}"

  defp fallback_class(:movie),
    do:
      "w-full h-full flex flex-col items-center justify-center bg-gradient-to-br from-zinc-800 to-zinc-900 p-2 text-center"

  defp fallback_class(:series), do: "w-full h-full flex items-center justify-center"

  defp fallback_icon(:movie), do: "hero-film"
  defp fallback_icon(:series), do: "hero-tv"

  defp fallback_icon_class(:movie), do: "size-6 text-brand/60 mb-1"
  defp fallback_icon_class(:series), do: "size-8 text-text-secondary/30"

  defp episode_item_title(episode), do: "Episódio #{episode.episode_num}"
end
