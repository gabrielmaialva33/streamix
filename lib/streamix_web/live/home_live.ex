defmodule StreamixWeb.HomeLive do
  use StreamixWeb, :live_view

  alias Streamix.Iptv

  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(page_title: "Início")
      |> assign(current_path: "/")
      |> load_public_catalog()
      |> load_user_data()

    {:ok, socket}
  end

  defp load_public_catalog(socket) do
    # Load public content for everyone (guests and logged in users)
    featured = Iptv.get_featured_content()
    stats = Iptv.get_public_stats()

    socket
    |> assign(featured: featured)
    |> assign(stats: stats)
    |> assign(movies: Iptv.list_public_movies(limit: 12))
    |> assign(series: Iptv.list_public_series(limit: 12))
    |> assign(channels: Iptv.list_public_channels(limit: 24))
  end

  defp load_user_data(socket) do
    case socket.assigns.current_scope do
      nil ->
        socket
        |> assign(favorites: [])
        |> assign(history: [])
        |> assign(featured_favorite: false)

      scope ->
        user_id = scope.user.id
        featured_favorite = check_featured_favorite(socket.assigns.featured, user_id)

        socket
        |> assign(favorites: Iptv.list_favorites(user_id, limit: 12))
        |> assign(history: Iptv.list_watch_history(user_id, limit: 6))
        |> assign(featured_favorite: featured_favorite)
    end
  end

  defp check_featured_favorite(nil, _user_id), do: false

  defp check_featured_favorite({type, content}, user_id) do
    content_type = if type == :movie, do: "movie", else: "series"
    Iptv.is_favorite?(user_id, content_type, content.id)
  end

  # ============================================
  # Event Handlers
  # ============================================

  def handle_event("toggle_featured_favorite", _, socket) do
    case {socket.assigns.current_scope, socket.assigns.featured} do
      {nil, _} ->
        {:noreply, socket}

      {_, nil} ->
        {:noreply, socket}

      {scope, {type, content}} ->
        user_id = scope.user.id
        content_type = if type == :movie, do: "movie", else: "series"
        is_favorite = socket.assigns.featured_favorite

        if is_favorite do
          Iptv.remove_favorite(user_id, content_type, content.id)
        else
          Iptv.add_favorite(user_id, %{
            content_type: content_type,
            content_id: content.id,
            content_name: content.title || content.name,
            content_icon: content.stream_icon || content.cover
          })
        end

        {:noreply, assign(socket, featured_favorite: !is_favorite)}
    end
  end

  def render(assigns) do
    ~H"""
    <div>
      <!-- Hero Section with Featured Content -->
      <.hero_section
        featured={@featured}
        stats={@stats}
        current_scope={@current_scope}
        featured_favorite={@featured_favorite}
      />

      <div class="space-y-6 sm:space-y-8 pb-12">
        <!-- Continue Watching (logged in only) -->
        <.content_carousel
          :if={@current_scope && @history != []}
          title="Continue Assistindo"
          items={@history}
          type={:history}
        />
        
    <!-- User's Favorites (logged in only) -->
        <.content_carousel
          :if={@current_scope && @favorites != []}
          title="Minha Lista"
          items={@favorites}
          type={:favorites}
        />
        
    <!-- Featured Movies -->
        <.content_carousel
          :if={@movies != []}
          title="Filmes em Destaque"
          items={@movies}
          type={:movies}
        />
        
    <!-- Featured Series -->
        <.content_carousel
          :if={@series != []}
          title="Séries Populares"
          items={@series}
          type={:series}
        />
        
    <!-- Live Channels -->
        <.content_carousel
          :if={@channels != []}
          title="TV ao Vivo"
          items={@channels}
          type={:channels}
        />
        
    <!-- Empty State when no content -->
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
            :if={@current_scope}
            navigate={~p"/providers"}
            class="inline-flex items-center gap-2 px-6 py-3 bg-brand text-white font-semibold rounded-md hover:bg-brand-hover transition-colors"
          >
            <.icon name="hero-plus" class="size-5" /> Adicionar Provedor
          </.link>
          <.link
            :if={!@current_scope}
            navigate={~p"/register"}
            class="inline-flex items-center gap-2 px-6 py-3 bg-brand text-white font-semibold rounded-md hover:bg-brand-hover transition-colors"
          >
            Criar Conta
          </.link>
        </div>
      </div>
    </div>
    """
  end

  # Hero Section Component
  defp hero_section(assigns) do
    ~H"""
    <div class="relative h-[45vh] sm:h-[60vh] lg:h-[70vh] min-h-[280px] sm:min-h-[400px] max-h-[800px] overflow-hidden -mt-16 sm:-mt-20 pt-14 sm:pt-16">
      <!-- Background Image -->
      <%= if @featured do %>
        <.hero_background featured={@featured} />
      <% else %>
        <.hero_fallback />
      <% end %>
      
    <!-- Gradients -->
      <div class="absolute inset-0 bg-gradient-to-t from-background via-background/60 to-transparent" />
      <div class="absolute inset-0 bg-gradient-to-r from-background via-background/40 to-transparent" />
      
    <!-- Content -->
      <div class="absolute inset-0 flex items-end">
        <div class="w-full px-[4%] pb-16 lg:pb-24">
          <%= if @featured do %>
            <.hero_content
              featured={@featured}
              current_scope={@current_scope}
              featured_favorite={@featured_favorite}
            />
          <% else %>
            <.hero_welcome stats={@stats} current_scope={@current_scope} />
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  defp hero_background(assigns) do
    {_type, content} = assigns.featured
    backdrop = get_backdrop(content)
    assigns = assign(assigns, :backdrop, backdrop)

    ~H"""
    <img
      :if={@backdrop}
      src={@backdrop}
      alt=""
      class="absolute inset-0 w-full h-full object-cover object-top hero-backdrop"
      loading="eager"
    />
    <div
      :if={!@backdrop}
      class="absolute inset-0 bg-gradient-to-br from-surface via-background to-surface hero-backdrop"
    />
    """
  end

  defp hero_fallback(assigns) do
    ~H"""
    <div class="absolute inset-0 bg-gradient-to-br from-brand/20 via-background to-accent/10" />
    """
  end

  defp hero_content(assigns) do
    {type, content} = assigns.featured
    assigns = assign(assigns, :type, type) |> assign(:content, content)

    ~H"""
    <div class="max-w-2xl animate-slide-up">
      <!-- Type Badge -->
      <div class="flex items-center gap-2 mb-4">
        <span class="px-2 py-1 text-xs font-semibold bg-brand text-white rounded">
          {if @type == :movie, do: "FILME", else: "SÉRIE"}
        </span>
        <span :if={@content.rating} class="flex items-center gap-1 text-sm text-text-secondary">
          <.icon name="hero-star-solid" class="size-4 text-yellow-500" />
          {Float.round(Decimal.to_float(@content.rating), 1)}
        </span>
        <span :if={@content.year} class="text-sm text-text-secondary">
          {@content.year}
        </span>
        <span :if={@content.genre} class="text-sm text-text-secondary">
          {String.split(@content.genre, ",") |> List.first() |> String.trim()}
        </span>
      </div>
      
    <!-- Title -->
      <h1 class="text-2xl sm:text-4xl md:text-6xl font-bold text-text-primary mb-2 sm:mb-4 drop-shadow-lg">
        {@content.title || @content.name}
      </h1>
      
    <!-- Plot (hidden on small mobile) -->
      <p
        :if={@content.plot}
        class="hidden sm:block text-base sm:text-lg text-text-secondary mb-4 sm:mb-6 line-clamp-2 sm:line-clamp-3 max-w-xl"
      >
        {@content.plot}
      </p>
      
    <!-- Actions -->
      <div class="flex gap-2 sm:gap-3">
        <.link
          navigate={content_path(@type, @content)}
          class="inline-flex items-center gap-1.5 sm:gap-2 px-4 sm:px-8 py-2 sm:py-3 bg-white text-black text-sm sm:text-base font-semibold rounded-md hover:bg-white/90 transition-colors"
        >
          <.icon name="hero-play-solid" class="size-4 sm:size-6" /> Assistir
        </.link>
        <.link
          navigate={content_info_path(@type, @content)}
          class="inline-flex items-center gap-1.5 sm:gap-2 px-4 sm:px-8 py-2 sm:py-3 bg-white/20 text-white text-sm sm:text-base font-semibold rounded-md hover:bg-white/30 transition-colors backdrop-blur-sm"
        >
          <.icon name="hero-information-circle" class="size-4 sm:size-6" /> <span class="hidden sm:inline">Mais </span>Info
        </.link>
        <%= if @current_scope do %>
          <button
            type="button"
            phx-click="toggle_featured_favorite"
            class={[
              "inline-flex items-center justify-center w-9 h-9 sm:w-12 sm:h-12 rounded-full transition-colors backdrop-blur-sm",
              @featured_favorite && "bg-white text-black hover:bg-white/90",
              !@featured_favorite && "bg-white/20 text-white hover:bg-white/30"
            ]}
            title={
              if @featured_favorite, do: "Remover da Minha Lista", else: "Adicionar à Minha Lista"
            }
          >
            <.icon
              name={if @featured_favorite, do: "hero-check", else: "hero-plus"}
              class="size-4 sm:size-6"
            />
          </button>
        <% end %>
      </div>
    </div>
    """
  end

  defp hero_welcome(assigns) do
    ~H"""
    <div class="max-w-2xl animate-slide-up">
      <h1 class="text-5xl md:text-7xl font-bold text-text-primary mb-6 tracking-tight">
        Streamix
      </h1>
      <p class="text-xl text-text-secondary mb-8 max-w-xl">
        Sua plataforma de streaming pessoal. TV ao vivo, filmes e séries de todos os seus provedores em um único lugar.
      </p>
      
    <!-- Stats -->
      <div
        :if={@stats.movies_count > 0 || @stats.series_count > 0 || @stats.channels_count > 0}
        class="flex gap-8 mb-8"
      >
        <div :if={@stats.movies_count > 0} class="text-center">
          <p class="text-3xl font-bold text-text-primary">{format_number(@stats.movies_count)}</p>
          <p class="text-sm text-text-secondary">Filmes</p>
        </div>
        <div :if={@stats.series_count > 0} class="text-center">
          <p class="text-3xl font-bold text-text-primary">{format_number(@stats.series_count)}</p>
          <p class="text-sm text-text-secondary">Séries</p>
        </div>
        <div :if={@stats.channels_count > 0} class="text-center">
          <p class="text-3xl font-bold text-text-primary">{format_number(@stats.channels_count)}</p>
          <p class="text-sm text-text-secondary">Canais</p>
        </div>
      </div>
      
    <!-- Actions -->
      <div class="flex gap-3">
        <%= if @current_scope do %>
          <.link
            navigate={~p"/providers"}
            class="inline-flex items-center gap-2 px-8 py-3 bg-white text-black font-semibold rounded-md hover:bg-white/90 transition-colors"
          >
            <.icon name="hero-play-solid" class="size-6" /> Explorar Conteúdo
          </.link>
        <% else %>
          <.link
            navigate={~p"/register"}
            class="inline-flex items-center gap-2 px-8 py-4 bg-brand text-white text-lg font-semibold rounded-md hover:bg-brand-hover transition-colors"
          >
            Começar Agora
          </.link>
          <.link
            navigate={~p"/login"}
            class="inline-flex items-center gap-2 px-8 py-4 bg-white/20 text-white text-lg font-semibold rounded-md hover:bg-white/30 transition-colors backdrop-blur-sm"
          >
            Entrar
          </.link>
        <% end %>
      </div>
    </div>
    """
  end

  # Content Carousel Component
  defp content_carousel(assigns) do
    see_more_path = get_see_more_path(assigns.type, assigns.items)
    assigns = assign(assigns, :see_more_path, see_more_path)

    ~H"""
    <div class="px-[4%]">
      <div class="flex items-center justify-between mb-3 sm:mb-4">
        <h2 class="text-base sm:text-xl font-semibold text-text-primary">{@title}</h2>
        <.link
          :if={@see_more_path}
          navigate={@see_more_path}
          class="hidden sm:flex text-sm text-text-secondary hover:text-text-primary transition-colors items-center gap-1"
        >
          Ver mais <.icon name="hero-chevron-right" class="size-4" />
        </.link>
      </div>
      <%= if @type == :channels do %>
        <!-- Grid layout for channels - 3 cols mobile, scrollable on larger -->
        <div class="grid grid-cols-3 gap-2 sm:grid-cols-none sm:grid-rows-2 sm:grid-flow-col sm:gap-4 sm:overflow-x-auto py-1 sm:py-2 scrollbar-hide scroll-smooth sm:auto-cols-[160px]">
          <.channel_card :for={channel <- Enum.take(@items, 6)} channel={channel} class="sm:hidden" />
          <.channel_card :for={channel <- @items} channel={channel} class="hidden sm:block" />
          <.see_more_card
            :if={@see_more_path}
            path={@see_more_path}
            type={@type}
            class="hidden sm:flex"
          />
        </div>
        <.link
          :if={@see_more_path && length(@items) > 6}
          navigate={@see_more_path}
          class="sm:hidden mt-3 flex items-center justify-center gap-2 py-2.5 text-sm text-text-secondary hover:text-text-primary bg-surface/50 rounded-lg transition-colors"
        >
          Ver todos os canais <.icon name="hero-arrow-right" class="size-4" />
        </.link>
      <% else %>
        <!-- Grid on mobile (3 cols), horizontal scroll on desktop -->
        <div class={[
          "grid grid-cols-3 gap-2 sm:flex sm:gap-4 sm:overflow-x-auto py-1 sm:py-2 scrollbar-hide scroll-smooth",
          @type in [:history] && "grid-cols-1 sm:grid-cols-none"
        ]}>
          <%= case @type do %>
            <% :movies -> %>
              <.movie_card :for={movie <- Enum.take(@items, 6)} movie={movie} class="sm:hidden" />
              <.movie_card :for={movie <- @items} movie={movie} class="hidden sm:block" />
            <% :series -> %>
              <.series_card :for={series <- Enum.take(@items, 6)} series={series} class="sm:hidden" />
              <.series_card :for={series <- @items} series={series} class="hidden sm:block" />
            <% :history -> %>
              <.history_item :for={entry <- Enum.take(@items, 3)} entry={entry} class="sm:hidden" />
              <.history_item :for={entry <- @items} entry={entry} class="hidden sm:block" />
            <% :favorites -> %>
              <.favorite_item :for={fav <- Enum.take(@items, 6)} favorite={fav} class="sm:hidden" />
              <.favorite_item :for={fav <- @items} favorite={fav} class="hidden sm:block" />
          <% end %>
          <.see_more_card
            :if={@see_more_path}
            path={@see_more_path}
            type={@type}
            class="hidden sm:flex"
          />
        </div>
        <.link
          :if={@see_more_path && length(@items) > 6 && @type not in [:history]}
          navigate={@see_more_path}
          class="sm:hidden mt-3 flex items-center justify-center gap-2 py-2.5 text-sm text-text-secondary hover:text-text-primary bg-surface/50 rounded-lg transition-colors"
        >
          Ver mais <.icon name="hero-arrow-right" class="size-4" />
        </.link>
      <% end %>
    </div>
    """
  end

  # See More Card at the end of carousel
  defp see_more_card(assigns) do
    assigns = assign_new(assigns, :class, fn -> nil end)

    # Different sizes based on content type
    card_class =
      case assigns.type do
        :channels -> "aspect-video w-[160px]"
        :history -> "aspect-video w-[280px]"
        :favorites -> "aspect-[2/3] w-[120px]"
        _ -> "aspect-[2/3] w-[180px]"
      end

    assigns = assign(assigns, :card_class, card_class)

    ~H"""
    <.link
      navigate={@path}
      class={[
        "group flex-shrink-0 rounded-lg overflow-hidden bg-surface/50 border border-white/10",
        "hover:bg-surface hover:border-white/20 transition-all duration-200",
        "items-center justify-center",
        @card_class,
        @class
      ]}
    >
      <div class="text-center p-4">
        <div class="w-12 h-12 mx-auto mb-2 rounded-full bg-white/10 group-hover:bg-white/20 flex items-center justify-center transition-colors">
          <.icon
            name="hero-arrow-right"
            class="size-6 text-white/70 group-hover:text-white transition-colors"
          />
        </div>
        <span class="text-sm text-white/70 group-hover:text-white transition-colors">Ver mais</span>
      </div>
    </.link>
    """
  end

  # Card Components
  defp movie_card(assigns) do
    assigns = assign_new(assigns, :class, fn -> nil end)

    ~H"""
    <.link
      navigate={~p"/browse/movies/#{@movie.id}"}
      class={[
        "group flex-shrink-0 w-full sm:w-[180px] rounded-lg overflow-hidden bg-surface content-card hover:ring-2 hover:ring-white/50",
        @class
      ]}
    >
      <div class="aspect-[2/3] bg-surface-hover relative">
        <img
          :if={@movie.stream_icon}
          src={@movie.stream_icon}
          alt={@movie.name}
          class="w-full h-full object-cover animate-fade-in"
          loading="lazy"
        />
        <div :if={!@movie.stream_icon} class="w-full h-full flex items-center justify-center">
          <.icon name="hero-film" class="size-8 sm:size-12 text-text-muted" />
        </div>
        <!-- Hover overlay (hidden on touch devices) -->
        <div class="absolute inset-0 bg-black/60 opacity-0 group-hover:opacity-100 transition-opacity hidden sm:flex items-center justify-center">
          <.icon name="hero-play-circle-solid" class="size-16 text-white" />
        </div>
        <!-- Rating badge -->
        <div
          :if={@movie.rating}
          class="absolute top-1 right-1 sm:top-2 sm:right-2 flex items-center gap-0.5 sm:gap-1 px-1 sm:px-1.5 py-0.5 bg-black/70 rounded text-[10px] sm:text-xs text-white"
        >
          <.icon name="hero-star-solid" class="size-2.5 sm:size-3 text-yellow-500" />
          {Float.round(Decimal.to_float(@movie.rating), 1)}
        </div>
      </div>
      <div class="p-1.5 sm:p-2">
        <h3 class="text-xs sm:text-sm font-medium text-text-primary truncate">
          {@movie.title || @movie.name}
        </h3>
        <p class="text-[10px] sm:text-xs text-text-muted">{@movie.year}</p>
      </div>
    </.link>
    """
  end

  defp series_card(assigns) do
    assigns = assign_new(assigns, :class, fn -> nil end)

    ~H"""
    <.link
      navigate={~p"/browse/series/#{@series.id}"}
      class={[
        "group flex-shrink-0 w-full sm:w-[180px] rounded-lg overflow-hidden bg-surface content-card hover:ring-2 hover:ring-white/50",
        @class
      ]}
    >
      <div class="aspect-[2/3] bg-surface-hover relative">
        <img
          :if={@series.cover}
          src={@series.cover}
          alt={@series.name}
          class="w-full h-full object-cover animate-fade-in"
          loading="lazy"
        />
        <div :if={!@series.cover} class="w-full h-full flex items-center justify-center">
          <.icon name="hero-tv" class="size-8 sm:size-12 text-text-muted" />
        </div>
        <!-- Hover overlay (hidden on touch devices) -->
        <div class="absolute inset-0 bg-black/60 opacity-0 group-hover:opacity-100 transition-opacity hidden sm:flex items-center justify-center">
          <.icon name="hero-play-circle-solid" class="size-16 text-white" />
        </div>
        <!-- Rating badge -->
        <div
          :if={@series.rating}
          class="absolute top-1 right-1 sm:top-2 sm:right-2 flex items-center gap-0.5 sm:gap-1 px-1 sm:px-1.5 py-0.5 bg-black/70 rounded text-[10px] sm:text-xs text-white"
        >
          <.icon name="hero-star-solid" class="size-2.5 sm:size-3 text-yellow-500" />
          {Float.round(Decimal.to_float(@series.rating), 1)}
        </div>
      </div>
      <div class="p-1.5 sm:p-2">
        <h3 class="text-xs sm:text-sm font-medium text-text-primary truncate">
          {@series.title || @series.name}
        </h3>
        <p class="text-[10px] sm:text-xs text-text-muted">
          {if @series.season_count && @series.season_count > 0,
            do: "#{@series.season_count} temp",
            else: @series.year}
        </p>
      </div>
    </.link>
    """
  end

  defp channel_card(assigns) do
    assigns = assign_new(assigns, :class, fn -> nil end)

    ~H"""
    <.link
      navigate={~p"/watch/live_channel/#{@channel.id}"}
      class={[
        "group rounded-lg overflow-hidden bg-surface content-card hover:ring-2 hover:ring-brand/50",
        @class
      ]}
    >
      <div class="aspect-video bg-surface-hover relative flex items-center justify-center">
        <img
          :if={@channel.stream_icon}
          src={@channel.stream_icon}
          alt={@channel.name}
          class="w-full h-full object-contain p-1.5 sm:p-2 animate-fade-in"
          loading="lazy"
        />
        <.icon :if={!@channel.stream_icon} name="hero-tv" class="size-6 sm:size-10 text-text-muted" />
        <!-- Live badge -->
        <div class="absolute top-1 left-1 sm:top-2 sm:left-2 flex items-center gap-0.5 sm:gap-1 px-1 sm:px-1.5 py-0.5 bg-brand rounded text-[8px] sm:text-xs text-white font-semibold">
          <span class="w-1 h-1 sm:w-1.5 sm:h-1.5 bg-white rounded-full animate-pulse" /> AO VIVO
        </div>
        <!-- Hover overlay (hidden on touch devices) -->
        <div class="absolute inset-0 bg-black/60 opacity-0 group-hover:opacity-100 transition-opacity hidden sm:flex items-center justify-center">
          <.icon name="hero-play-solid" class="size-12 text-white" />
        </div>
      </div>
      <div class="p-1.5 sm:p-2">
        <h3 class="text-[10px] sm:text-sm font-medium text-text-primary truncate">{@channel.name}</h3>
      </div>
    </.link>
    """
  end

  defp history_item(assigns) do
    assigns = assign_new(assigns, :class, fn -> nil end)

    ~H"""
    <.link
      navigate={watch_path(@entry.content_type, @entry.content_id)}
      class={[
        "group flex-shrink-0 w-full sm:w-[280px] rounded-lg overflow-hidden bg-surface hover:ring-2 hover:ring-white/50 transition-all duration-200",
        @class
      ]}
    >
      <div class="aspect-video bg-surface-hover relative flex items-center justify-center">
        <img
          :if={@entry.content_icon}
          src={@entry.content_icon}
          alt={@entry.content_name}
          class="w-full h-full object-cover"
          loading="lazy"
        />
        <.icon
          :if={!@entry.content_icon}
          name={content_type_icon(@entry.content_type)}
          class="size-8 sm:size-12 text-text-muted"
        />
        <!-- Progress bar -->
        <div
          :if={@entry.progress_seconds && @entry.duration_seconds}
          class="absolute bottom-0 left-0 right-0 h-1 bg-white/30"
        >
          <div class="h-full bg-brand" style={"width: #{progress_percent(@entry)}%"} />
        </div>
        <!-- Hover overlay (hidden on touch devices) -->
        <div class="absolute inset-0 bg-black/60 opacity-0 group-hover:opacity-100 transition-opacity hidden sm:flex items-center justify-center">
          <.icon name="hero-play-solid" class="size-12 text-white" />
        </div>
      </div>
      <div class="p-2 sm:p-3">
        <h3 class="text-xs sm:text-sm font-medium text-text-primary truncate">
          {@entry.content_name || "Desconhecido"}
        </h3>
        <p class="text-[10px] sm:text-xs text-text-muted flex items-center gap-1 sm:gap-2">
          <span class="px-1 sm:px-1.5 py-0.5 rounded bg-surface-hover">
            {format_content_type(@entry.content_type)}
          </span>
          <span>{format_relative_time(@entry.watched_at)}</span>
        </p>
      </div>
    </.link>
    """
  end

  defp favorite_item(assigns) do
    assigns = assign_new(assigns, :class, fn -> nil end)

    ~H"""
    <.link
      navigate={watch_path(@favorite.content_type, @favorite.content_id)}
      class={[
        "group flex-shrink-0 w-full sm:w-[120px] rounded-lg overflow-hidden bg-surface content-card hover:ring-2 hover:ring-white/50",
        @class
      ]}
    >
      <div class="aspect-[2/3] bg-surface-hover relative flex items-center justify-center">
        <img
          :if={@favorite.content_icon}
          src={@favorite.content_icon}
          alt={@favorite.content_name}
          class="w-full h-full object-cover"
          loading="lazy"
        />
        <.icon
          :if={!@favorite.content_icon}
          name={content_type_icon(@favorite.content_type)}
          class="size-6 sm:size-10 text-text-muted"
        />
        <!-- Hover overlay (hidden on touch devices) -->
        <div class="absolute inset-0 bg-black/60 opacity-0 group-hover:opacity-100 transition-opacity hidden sm:flex items-center justify-center">
          <.icon name="hero-play-solid" class="size-10 text-white" />
        </div>
      </div>
    </.link>
    """
  end

  # Helper functions
  defp get_backdrop(content) do
    case content.backdrop_path do
      [first | _] -> first
      _ -> nil
    end
  end

  defp content_path(:movie, movie), do: ~p"/watch/movie/#{movie.id}"
  defp content_path(:series, series), do: ~p"/browse/series/#{series.id}"

  defp content_info_path(:movie, movie), do: ~p"/browse/movies/#{movie.id}"
  defp content_info_path(:series, series), do: ~p"/browse/series/#{series.id}"

  defp watch_path("live_channel", id), do: ~p"/watch/live_channel/#{id}"
  defp watch_path("live", id), do: ~p"/watch/live_channel/#{id}"
  defp watch_path("movie", id), do: ~p"/watch/movie/#{id}"
  defp watch_path("episode", id), do: ~p"/watch/episode/#{id}"
  defp watch_path(_, id), do: ~p"/watch/movie/#{id}"

  defp content_type_icon("live"), do: "hero-tv"
  defp content_type_icon("movie"), do: "hero-film"
  defp content_type_icon("series"), do: "hero-video-camera"
  defp content_type_icon("episode"), do: "hero-play"
  defp content_type_icon(_), do: "hero-film"

  defp format_content_type("live"), do: "TV"
  defp format_content_type("movie"), do: "Filme"
  defp format_content_type("series"), do: "Série"
  defp format_content_type("episode"), do: "Episódio"
  defp format_content_type(_), do: "Vídeo"

  defp progress_percent(%{progress_seconds: progress, duration_seconds: duration})
       when is_number(progress) and is_number(duration) and duration > 0 do
    min(round(progress / duration * 100), 100)
  end

  defp progress_percent(_), do: 0

  defp format_relative_time(nil), do: ""

  defp format_relative_time(datetime) do
    now = DateTime.utc_now()
    diff = DateTime.diff(now, datetime, :second)

    cond do
      diff < 60 -> "agora"
      diff < 3600 -> "#{div(diff, 60)} min"
      diff < 86_400 -> "#{div(diff, 3600)} h"
      diff < 604_800 -> "#{div(diff, 86_400)} dias"
      true -> Calendar.strftime(datetime, "%d/%m")
    end
  end

  defp format_number(n) when n >= 1000 do
    "#{Float.round(n / 1000, 1)}k"
  end

  defp format_number(n), do: to_string(n)

  # Get the "See More" path based on content type
  defp get_see_more_path(:movies, _), do: ~p"/browse/movies"
  defp get_see_more_path(:series, _), do: ~p"/browse/series"
  defp get_see_more_path(:channels, _), do: ~p"/browse"
  defp get_see_more_path(:history, _), do: ~p"/history"
  defp get_see_more_path(:favorites, _), do: ~p"/favorites"
  defp get_see_more_path(_, _), do: nil
end
