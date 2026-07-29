defmodule StreamixWeb.Content.DetailComponents do
  @moduledoc """
  Layout, gallery, and episode components shared across movie, series, and
  episode pages. Compact metadata lives in `DetailComponents.Badges`; user
  actions live in `DetailComponents.Actions`.
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

  defdelegate detail_format_duration(seconds),
    to: StreamixWeb.Content.DetailComponents.Badges,
    as: :format_duration

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
