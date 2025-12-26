defmodule StreamixWeb.HomeLive do
  use StreamixWeb, :live_view

  import StreamixWeb.AppComponents

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
    |> assign(channels: Iptv.list_public_channels(limit: 12))
  end

  defp load_user_data(socket) do
    case socket.assigns.current_scope do
      nil ->
        socket
        |> assign(favorites: [])
        |> assign(history: [])

      scope ->
        user_id = scope.user.id

        socket
        |> assign(favorites: Iptv.list_favorites(user_id, limit: 12))
        |> assign(history: Iptv.list_watch_history(user_id, limit: 6))
    end
  end

  def render(assigns) do
    ~H"""
    <div>
      <!-- Hero Section with Featured Content -->
      <.hero_section featured={@featured} stats={@stats} current_scope={@current_scope} />

      <div class="space-y-8 pb-12">
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
    <div class="relative h-[70vh] min-h-[500px] max-h-[800px] overflow-hidden">
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
            <.hero_content featured={@featured} current_scope={@current_scope} />
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
      <h1 class="text-4xl md:text-6xl font-bold text-text-primary mb-4 drop-shadow-lg">
        {@content.title || @content.name}
      </h1>
      
    <!-- Plot -->
      <p :if={@content.plot} class="text-lg text-text-secondary mb-6 line-clamp-3 max-w-xl">
        {@content.plot}
      </p>
      
    <!-- Actions -->
      <div class="flex gap-3">
        <.link
          navigate={content_path(@type, @content)}
          class="inline-flex items-center gap-2 px-8 py-3 bg-white text-black font-semibold rounded-md hover:bg-white/90 transition-colors"
        >
          <.icon name="hero-play-solid" class="size-6" /> Assistir
        </.link>
        <.link
          navigate={content_info_path(@type, @content)}
          class="inline-flex items-center gap-2 px-6 py-3 bg-white/20 text-white font-semibold rounded-md hover:bg-white/30 transition-colors backdrop-blur-sm"
        >
          <.icon name="hero-information-circle" class="size-6" /> Mais Informações
        </.link>
        <%= if @current_scope do %>
          <button
            type="button"
            class="inline-flex items-center justify-center w-12 h-12 bg-white/20 text-white rounded-full hover:bg-white/30 transition-colors backdrop-blur-sm"
          >
            <.icon name="hero-plus" class="size-6" />
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
    ~H"""
    <div class="px-[4%]">
      <h2 class="text-xl font-semibold text-text-primary mb-4">{@title}</h2>
      <div class="flex gap-4 overflow-x-auto py-2 scrollbar-hide scroll-smooth">
        <%= case @type do %>
          <% :movies -> %>
            <.movie_card :for={movie <- @items} movie={movie} />
          <% :series -> %>
            <.series_card :for={series <- @items} series={series} />
          <% :channels -> %>
            <.channel_card :for={channel <- @items} channel={channel} />
          <% :history -> %>
            <.history_item :for={entry <- @items} entry={entry} />
          <% :favorites -> %>
            <.favorite_item :for={fav <- @items} favorite={fav} />
        <% end %>
      </div>
    </div>
    """
  end

  # Card Components
  defp movie_card(assigns) do
    ~H"""
    <.link
      navigate={~p"/watch/movie/#{@movie.id}"}
      class="group flex-shrink-0 w-[180px] rounded-lg overflow-hidden bg-surface content-card hover:ring-2 hover:ring-white/50"
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
          <.icon name="hero-film" class="size-12 text-text-muted" />
        </div>
        <!-- Hover overlay -->
        <div class="absolute inset-0 bg-black/60 opacity-0 group-hover:opacity-100 transition-opacity flex items-center justify-center">
          <.icon name="hero-play-circle-solid" class="size-16 text-white" />
        </div>
        <!-- Rating badge -->
        <div
          :if={@movie.rating}
          class="absolute top-2 right-2 flex items-center gap-1 px-1.5 py-0.5 bg-black/70 rounded text-xs text-white"
        >
          <.icon name="hero-star-solid" class="size-3 text-yellow-500" />
          {Float.round(Decimal.to_float(@movie.rating), 1)}
        </div>
      </div>
      <div class="p-2">
        <h3 class="text-sm font-medium text-text-primary truncate">{@movie.title || @movie.name}</h3>
        <p class="text-xs text-text-muted">{@movie.year}</p>
      </div>
    </.link>
    """
  end

  defp series_card(assigns) do
    ~H"""
    <.link
      navigate={~p"/providers/#{@series.provider_id}/series/#{@series.id}"}
      class="group flex-shrink-0 w-[180px] rounded-lg overflow-hidden bg-surface content-card hover:ring-2 hover:ring-white/50"
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
          <.icon name="hero-tv" class="size-12 text-text-muted" />
        </div>
        <!-- Hover overlay -->
        <div class="absolute inset-0 bg-black/60 opacity-0 group-hover:opacity-100 transition-opacity flex items-center justify-center">
          <.icon name="hero-play-circle-solid" class="size-16 text-white" />
        </div>
        <!-- Rating badge -->
        <div
          :if={@series.rating}
          class="absolute top-2 right-2 flex items-center gap-1 px-1.5 py-0.5 bg-black/70 rounded text-xs text-white"
        >
          <.icon name="hero-star-solid" class="size-3 text-yellow-500" />
          {Float.round(Decimal.to_float(@series.rating), 1)}
        </div>
      </div>
      <div class="p-2">
        <h3 class="text-sm font-medium text-text-primary truncate">
          {@series.title || @series.name}
        </h3>
        <p class="text-xs text-text-muted">
          {if @series.season_count && @series.season_count > 0,
            do: "#{@series.season_count} temporadas",
            else: @series.year}
        </p>
      </div>
    </.link>
    """
  end

  defp channel_card(assigns) do
    ~H"""
    <.link
      navigate={~p"/watch/live_channel/#{@channel.id}"}
      class="group flex-shrink-0 w-[160px] rounded-lg overflow-hidden bg-surface content-card hover:ring-2 hover:ring-brand/50"
    >
      <div class="aspect-video bg-surface-hover relative flex items-center justify-center">
        <img
          :if={@channel.stream_icon}
          src={@channel.stream_icon}
          alt={@channel.name}
          class="w-full h-full object-contain p-2 animate-fade-in"
          loading="lazy"
        />
        <.icon :if={!@channel.stream_icon} name="hero-tv" class="size-10 text-text-muted" />
        <!-- Live badge -->
        <div class="absolute top-2 left-2 flex items-center gap-1 px-1.5 py-0.5 bg-brand rounded text-xs text-white font-semibold">
          <span class="w-1.5 h-1.5 bg-white rounded-full animate-pulse" /> AO VIVO
        </div>
        <!-- Hover overlay -->
        <div class="absolute inset-0 bg-black/60 opacity-0 group-hover:opacity-100 transition-opacity flex items-center justify-center">
          <.icon name="hero-play-solid" class="size-12 text-white" />
        </div>
      </div>
      <div class="p-2">
        <h3 class="text-sm font-medium text-text-primary truncate">{@channel.name}</h3>
      </div>
    </.link>
    """
  end

  defp history_item(assigns) do
    ~H"""
    <.link
      navigate={watch_path(@entry.content_type, @entry.content_id)}
      class="group flex-shrink-0 w-[280px] rounded-lg overflow-hidden bg-surface hover:ring-2 hover:ring-white/50 transition-all duration-200"
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
          class="size-12 text-text-muted"
        />
        <!-- Progress bar -->
        <div
          :if={@entry.progress_seconds && @entry.duration_seconds}
          class="absolute bottom-0 left-0 right-0 h-1 bg-white/30"
        >
          <div class="h-full bg-brand" style={"width: #{progress_percent(@entry)}%"} />
        </div>
        <!-- Hover overlay -->
        <div class="absolute inset-0 bg-black/60 opacity-0 group-hover:opacity-100 transition-opacity flex items-center justify-center">
          <.icon name="hero-play-solid" class="size-12 text-white" />
        </div>
      </div>
      <div class="p-3">
        <h3 class="text-sm font-medium text-text-primary truncate">
          {@entry.content_name || "Desconhecido"}
        </h3>
        <p class="text-xs text-text-muted flex items-center gap-2">
          <span class="px-1.5 py-0.5 rounded bg-surface-hover">
            {format_content_type(@entry.content_type)}
          </span>
          <span>{format_relative_time(@entry.watched_at)}</span>
        </p>
      </div>
    </.link>
    """
  end

  defp favorite_item(assigns) do
    ~H"""
    <.link
      navigate={watch_path(@favorite.content_type, @favorite.content_id)}
      class="group flex-shrink-0 w-[120px] rounded-lg overflow-hidden bg-surface content-card hover:ring-2 hover:ring-white/50"
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
          class="size-10 text-text-muted"
        />
        <!-- Hover overlay -->
        <div class="absolute inset-0 bg-black/60 opacity-0 group-hover:opacity-100 transition-opacity flex items-center justify-center">
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
  defp content_path(:series, series), do: ~p"/providers/#{series.provider_id}/series/#{series.id}"

  defp content_info_path(:movie, movie), do: ~p"/providers/#{movie.provider_id}/movies"

  defp content_info_path(:series, series),
    do: ~p"/providers/#{series.provider_id}/series/#{series.id}"

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
end
