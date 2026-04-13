defmodule StreamixWeb.HomeComponents do
  @moduledoc """
  UI components and formatting helpers for the Home/Landing page.
  """
  use Phoenix.Component
  use StreamixWeb, :verified_routes
  import StreamixWeb.CoreComponents
  import StreamixWeb.AppComponents
  import StreamixWeb.ContentComponents
  alias Streamix.Iptv
  alias StreamixWeb.Helpers.ImageProxy

  def render_landing_page(assigns) do
    ~H"""
    <%!-- Hero: full-screen with poster background --%>
    <div class="relative min-h-[95vh] flex items-center justify-center overflow-hidden -mt-16 sm:-mt-20">
      <%!-- Background image + edge fades --%>
      <div class="absolute inset-0 auth-branded-bg" />
      <div class="absolute inset-0 bg-gradient-to-t from-background via-background/60 to-black/40" />
      <div class="absolute inset-0 bg-gradient-to-b from-black/70 via-transparent to-transparent h-32" />
      <div class="absolute inset-0 bg-gradient-to-r from-background via-transparent to-background" />

      <%!-- Content --%>
      <div class="relative z-10 text-center px-6 max-w-3xl mx-auto">
        <h1 class="text-4xl sm:text-5xl lg:text-6xl font-bold text-white tracking-tight leading-tight mb-4">
          Filmes, séries e TV ao vivo, tudo em um só lugar
        </h1>
        <p class="text-lg sm:text-xl text-white/70 mb-8 max-w-xl mx-auto">
          Reúna todos os seus provedores IPTV em uma interface cinematográfica.
        </p>
        <div class="flex flex-col sm:flex-row items-center justify-center gap-3 sm:gap-4">
          <.link
            navigate={~p"/register"}
            class="w-full sm:w-auto inline-flex items-center justify-center gap-2 px-8 py-4 bg-brand text-white text-lg font-semibold rounded-md hover:bg-brand-hover transition-colors"
          >
            Começar agora <.icon name="hero-chevron-right" class="size-5" />
          </.link>
          <.link
            navigate={~p"/login"}
            class="w-full sm:w-auto inline-flex items-center justify-center gap-2 px-8 py-4 bg-white/10 text-white text-lg font-semibold rounded-md hover:bg-white/20 transition-colors backdrop-blur-sm border border-white/10"
          >
            Entrar
          </.link>
        </div>
      </div>
    </div>

    <%!-- Trending preview --%>
    <div :if={@top_10 != []} class="relative z-10 -mt-16 pb-8">
      <.render_top_10 title="Em alta no Streamix" items={@top_10} />
    </div>

    <%!-- Features section --%>
    <.landing_features />

    <%!-- Content preview carousels --%>
    <div class="space-y-8 py-8">
      <.render_content_carousel
        :if={@movies != []}
        title="Filmes populares"
        items={@movies}
        type={:movies}
        progress_map={%{}}
      />
      <.render_content_carousel
        :if={@series != []}
        title="Séries em destaque"
        items={@series}
        type={:series}
        progress_map={%{}}
      />
    </div>

    <%!-- FAQ section --%>
    <.landing_faq />

    <%!-- Bottom CTA --%>
    <div class="text-center py-16 px-6 border-t border-white/5">
      <h2 class="text-2xl sm:text-3xl font-bold text-white mb-4">
        Pronto para começar?
      </h2>
      <p class="text-white/60 mb-6">
        Crie sua conta e conecte seus provedores em minutos.
      </p>
      <.link
        navigate={~p"/register"}
        class="inline-flex items-center gap-2 px-8 py-4 bg-brand text-white text-lg font-semibold rounded-md hover:bg-brand-hover transition-colors"
      >
        Começar agora <.icon name="hero-chevron-right" class="size-5" />
      </.link>
    </div>
    """
  end

  def landing_features(assigns) do
    ~H"""
    <div class="py-16 sm:py-20 px-[4%] border-t border-white/5">
      <h2 class="text-2xl sm:text-3xl font-bold text-white text-center mb-12">
        Mais motivos para usar o Streamix
      </h2>
      <div class="grid sm:grid-cols-2 lg:grid-cols-4 gap-4">
        <.feature_card
          icon="hero-tv"
          title="Assista em qualquer tela"
          description="Smart TV, celular, tablet ou computador. Seus conteúdos te acompanham."
          gradient="from-blue-500/20 to-blue-600/5"
        />
        <.feature_card
          icon="hero-server-stack"
          title="Múltiplos provedores"
          description="Conecte quantos provedores IPTV quiser e veja tudo em um catálogo unificado."
          gradient="from-purple-500/20 to-purple-600/5"
        />
        <.feature_card
          icon="hero-magnifying-glass"
          title="Busca inteligente"
          description="Encontre o que quer com busca semântica por IA. Pesquise por tema, clima ou descrição."
          gradient="from-green-500/20 to-green-600/5"
        />
        <.feature_card
          icon="hero-users"
          title="Watch Party"
          description="Assista junto com amigos em tempo real, sincronizado e com chat ao vivo."
          gradient="from-pink-500/20 to-pink-600/5"
        />
      </div>
    </div>
    """
  end

  attr :icon, :string, required: true
  attr :title, :string, required: true
  attr :description, :string, required: true
  attr :gradient, :string, required: true

  def feature_card(assigns) do
    ~H"""
    <div class={"rounded-xl bg-gradient-to-br #{@gradient} border border-white/[0.06] p-6 sm:p-8"}>
      <div class="w-12 h-12 rounded-lg bg-white/[0.06] flex items-center justify-center mb-4">
        <.icon name={@icon} class="size-6 text-white/80" />
      </div>
      <h3 class="text-lg font-semibold text-white mb-2">{@title}</h3>
      <p class="text-sm text-white/50 leading-relaxed">{@description}</p>
    </div>
    """
  end

  def landing_faq(assigns) do
    ~H"""
    <div class="py-16 sm:py-20 px-[4%] border-t border-white/5">
      <h2 class="text-2xl sm:text-3xl font-bold text-white text-center mb-10">
        Perguntas frequentes
      </h2>
      <div class="max-w-2xl mx-auto space-y-2">
        <.faq_item question="O que é o Streamix?">
          O Streamix é uma plataforma que reúne múltiplos provedores IPTV em uma única interface cinematográfica. Você conecta seus provedores e assiste filmes, séries e TV ao vivo tudo em um só lugar.
        </.faq_item>
        <.faq_item question="Preciso de um provedor IPTV?">
          Sim. O Streamix é um agregador — ele organiza e exibe o conteúdo dos seus provedores existentes. Você pode conectar provedores Xtream Codes ou GIndex (Google Drive).
        </.faq_item>
        <.faq_item question="Posso usar em vários dispositivos?">
          Sim! O Streamix funciona em qualquer dispositivo com navegador web: Smart TV, celular, tablet, notebook ou desktop. Basta acessar pelo navegador.
        </.faq_item>
        <.faq_item question="O que é a busca por IA?">
          Nossa busca semântica entende o que você quer além das palavras. Pesquise por "filme de ação anos 80" ou "série de suspense psicológico" e encontre resultados relevantes.
        </.faq_item>
        <.faq_item question="O que é Watch Party?">
          Watch Party permite assistir junto com amigos em tempo real. Crie uma sala, compartilhe o link e assistam sincronizados com chat ao vivo.
        </.faq_item>
      </div>
    </div>
    """
  end

  attr :question, :string, required: true
  slot :inner_block, required: true

  def faq_item(assigns) do
    ~H"""
    <details class="group rounded-lg bg-white/[0.04] border border-white/[0.06] overflow-hidden">
      <summary class="flex items-center justify-between cursor-pointer px-6 py-5 text-white font-medium hover:bg-white/[0.02] transition-colors select-none">
        <span>{@question}</span>
        <.icon
          name="hero-plus"
          class="size-5 text-white/50 shrink-0 transition-transform group-open:rotate-45"
        />
      </summary>
      <div class="px-6 pb-5 text-sm text-white/60 leading-relaxed border-t border-white/[0.04] pt-4">
        {render_slot(@inner_block)}
      </div>
    </details>
    """
  end

  # ============================================
  # Authenticated Home (Logged in)
  # ============================================

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

  # Hero Section Component
  def render_hero_section(assigns) do
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
          <.hero_content
            :if={@featured}
            featured={@featured}
            current_scope={@current_scope}
            featured_favorite={@featured_favorite}
          />
        </div>
      </div>
    </div>
    """
  end

  def hero_background(assigns) do
    {_type, content} = assigns.featured
    backdrop = get_backdrop(content)
    trailer_id = Map.get(content, :youtube_trailer)

    assigns =
      assigns
      |> assign(:backdrop, backdrop)
      |> assign(:trailer_id, trailer_id)

    ~H"""
    <%!-- Poster background (always rendered as base) --%>
    <img
      :if={@backdrop}
      src={@backdrop}
      alt=""
      class="absolute inset-0 w-full h-full object-cover object-top hero-backdrop"
      loading="eager"
      id="hero-poster"
    />
    <div
      :if={!@backdrop}
      class="absolute inset-0 bg-gradient-to-br from-surface via-background to-surface hero-backdrop"
    />
    <%!-- YouTube trailer overlay (auto-play muted) --%>
    <div
      :if={@trailer_id}
      id="hero-trailer-container"
      phx-hook=".HeroTrailer"
      data-trailer-id={@trailer_id}
      class="absolute inset-0 opacity-0 transition-opacity duration-1000 pointer-events-none"
    >
      <div id="hero-trailer-player" class="w-full h-full"></div>
    </div>
    <%!-- Mute/unmute toggle --%>
    <button
      :if={@trailer_id}
      id="hero-mute-toggle"
      type="button"
      class="absolute bottom-20 sm:bottom-24 right-[4%] z-20 w-9 h-9 sm:w-11 sm:h-11 rounded-full bg-surface/50 backdrop-blur-sm border border-white/20 flex items-center justify-center text-white/70 hover:text-white hover:bg-surface/70 transition-all opacity-0"
      data-muted="true"
    >
      <.icon name="hero-speaker-x-mark" class="size-4 sm:size-5 hero-icon-muted" />
      <.icon name="hero-speaker-wave" class="size-4 sm:size-5 hero-icon-unmuted hidden" />
    </button>

    <script :type={Phoenix.LiveView.ColocatedHook} name=".HeroTrailer">
      export default {
        mounted() {
          this.trailerId = this.el.dataset.trailerId
          this.muted = true
          this.loaded = false
          this.timeout = null

          // Don't auto-play on mobile (saves bandwidth)
          if (window.innerWidth < 768) return

          // Load YouTube IFrame API if not already loaded
          if (!window.YT) {
            const tag = document.createElement('script')
            tag.src = 'https://www.youtube.com/iframe_api'
            document.head.appendChild(tag)
            window.onYouTubeIframeAPIReady = () => this.createPlayer()
          } else {
            this.createPlayer()
          }

          // Mute toggle
          const muteBtn = document.getElementById('hero-mute-toggle')
          if (muteBtn) {
            muteBtn.addEventListener('click', () => this.toggleMute())
          }
        },

        createPlayer() {
          this.player = new YT.Player('hero-trailer-player', {
            videoId: this.trailerId,
            playerVars: {
              autoplay: 1,
              mute: 1,
              controls: 0,
              showinfo: 0,
              rel: 0,
              modestbranding: 1,
              loop: 0,
              playsinline: 1,
              start: 5,
              enablejsapi: 1,
              origin: window.location.origin
            },
            events: {
              onReady: (e) => this.onReady(e),
              onStateChange: (e) => this.onStateChange(e)
            }
          })
        },

        onReady(event) {
          event.target.mute()
          // Fade in video after a brief delay
          setTimeout(() => {
            this.el.style.opacity = '1'
            this.loaded = true
            // Show mute button
            const muteBtn = document.getElementById('hero-mute-toggle')
            if (muteBtn) muteBtn.style.opacity = '1'
          }, 500)

          // Auto-stop after 40 seconds (Netflix-style)
          this.timeout = setTimeout(() => this.fadeOut(), 40000)
        },

        onStateChange(event) {
          // Video ended - fade back to poster
          if (event.data === YT.PlayerState.ENDED) {
            this.fadeOut()
          }
        },

        fadeOut() {
          this.el.style.opacity = '0'
          const muteBtn = document.getElementById('hero-mute-toggle')
          if (muteBtn) muteBtn.style.opacity = '0'
          if (this.player) {
            setTimeout(() => this.player.pauseVideo(), 1000)
          }
        },

        toggleMute() {
          if (!this.player) return
          const muteBtn = document.getElementById('hero-mute-toggle')
          const mutedIcon = muteBtn?.querySelector('.hero-icon-muted')
          const unmutedIcon = muteBtn?.querySelector('.hero-icon-unmuted')
          if (this.muted) {
            this.player.unMute()
            this.player.setVolume(30)
            this.muted = false
            if (mutedIcon) mutedIcon.classList.add('hidden')
            if (unmutedIcon) unmutedIcon.classList.remove('hidden')
          } else {
            this.player.mute()
            this.muted = true
            if (mutedIcon) mutedIcon.classList.remove('hidden')
            if (unmutedIcon) unmutedIcon.classList.add('hidden')
          }
        },

        destroyed() {
          if (this.timeout) clearTimeout(this.timeout)
          if (this.player) this.player.destroy()
        }
      }
    </script>
    """
  end

  def hero_fallback(assigns) do
    ~H"""
    <div class="absolute inset-0 bg-gradient-to-br from-brand/20 via-background to-accent/10" />
    """
  end

  def hero_content(assigns) do
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
        <span :if={@content.genres != []} class="text-sm text-text-secondary">
          {List.first(@content.genres).name}
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
          class="inline-flex items-center gap-1.5 sm:gap-2 px-4 sm:px-8 py-2 sm:py-3 bg-surface/60 text-text-primary text-sm sm:text-base font-semibold rounded-md hover:bg-surface/80 transition-colors backdrop-blur-sm border border-border"
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
              !@featured_favorite &&
                "bg-surface/60 text-text-primary hover:bg-surface/80 border border-border"
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

  # Carousel scroll arrows (Netflix-style)
  def carousel_arrows(assigns) do
    ~H"""
    <div
      id={@id}
      phx-hook=".ScrollArrows"
      class="hidden sm:block relative group/carousel"
    >
      {render_slot(@inner_block)}
      <%!-- Left arrow --%>
      <button
        type="button"
        data-scroll-dir="left"
        class="carousel-arrow-left absolute left-0 top-0 bottom-0 z-10 w-10 flex items-center justify-center bg-gradient-to-r from-background/90 to-transparent opacity-0 group-hover/carousel:opacity-100 transition-opacity cursor-pointer disabled:hidden"
      >
        <.icon name="hero-chevron-left" class="size-6 text-white" />
      </button>
      <%!-- Right arrow --%>
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

          // Initial state
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

  # Content Carousel Component
  def render_content_carousel(assigns) do
    see_more_path = get_see_more_path(assigns.type, assigns.items)
    carousel_id = "carousel-#{assigns.type}-#{System.unique_integer([:positive])}"

    assigns =
      assigns
      |> assign(:see_more_path, see_more_path)
      |> assign(:carousel_id, carousel_id)
      |> assign_new(:icon, fn -> nil end)
      |> assign_new(:progress_map, fn -> %{} end)

    ~H"""
    <div class="px-[4%]">
      <div class="flex items-center justify-between mb-3 sm:mb-4">
        <h2 class="text-base sm:text-xl font-semibold text-text-primary flex items-center gap-2">
          <.icon :if={@icon} name={@icon} class="size-5 text-brand" />
          {@title}
        </h2>
        <.link
          :if={@see_more_path}
          navigate={@see_more_path}
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
              :for={channel <- Enum.take(@items, 6)}
              channel={channel}
              class="sm:hidden"
            />
            <.channel_card :for={channel <- @items} channel={channel} class="hidden sm:block" />
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
          navigate={@see_more_path}
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
                  :for={movie <- Enum.take(@items, 6)}
                  movie={movie}
                  progress={Map.get(@progress_map, movie.id)}
                  class="sm:hidden"
                />
                <.render_movie_card
                  :for={movie <- @items}
                  movie={movie}
                  progress={Map.get(@progress_map, movie.id)}
                  class="hidden sm:block"
                />
              <% :series -> %>
                <.render_series_card
                  :for={series <- Enum.take(@items, 6)}
                  series={series}
                  progress={Map.get(@progress_map, series.id)}
                  class="sm:hidden"
                />
                <.render_series_card
                  :for={series <- @items}
                  series={series}
                  progress={Map.get(@progress_map, series.id)}
                  class="hidden sm:block"
                />
              <% :history -> %>
                <.history_item
                  :for={entry <- Enum.take(@items, 3)}
                  entry={entry}
                  class="sm:hidden"
                />
                <.history_item :for={entry <- @items} entry={entry} class="hidden sm:block" />
              <% :favorites -> %>
                <.favorite_item
                  :for={fav <- Enum.take(@items, 6)}
                  favorite={fav}
                  class="sm:hidden"
                />
                <.favorite_item :for={fav <- @items} favorite={fav} class="hidden sm:block" />
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
          navigate={@see_more_path}
          class="sm:hidden mt-3 flex items-center justify-center gap-2 py-2.5 text-sm text-text-secondary hover:text-text-primary bg-surface/50 rounded-lg transition-colors"
        >
          Ver mais <.icon name="hero-arrow-right" class="size-4" />
        </.link>
      <% end %>
    </div>
    """
  end

  # AI-Powered Trending Section with Filters
  def render_ai_trending_section(assigns) do
    assigns = assign_new(assigns, :progress_map, fn -> %{} end)

    ~H"""
    <div class="px-[4%]">
      <.section_header
        title="Em Alta Agora"
        icon="hero-fire-solid"
        icon_class="text-orange-500"
        genre_filters={@genre_filters}
        period_filters={@period_filters}
        selected_genre={@selected_genre}
        selected_period={@selected_period}
        on_genre_change="filter_trending_genre"
        on_period_change="filter_trending_period"
        see_more_path={~p"/browse/movies"}
        ai_powered={@ai_powered}
      />
      <.carousel_arrows id="carousel-trending">
        <div
          data-carousel-track
          class="grid grid-cols-3 gap-2 sm:flex sm:gap-4 sm:overflow-x-auto py-1 sm:py-2 scrollbar-hide scroll-smooth"
        >
          <.render_movie_card
            :for={movie <- Enum.take(@items, 6)}
            movie={movie}
            progress={Map.get(@progress_map, movie.id)}
            class="sm:hidden"
          />
          <.render_movie_card
            :for={movie <- @items}
            movie={movie}
            progress={Map.get(@progress_map, movie.id)}
            class="hidden sm:block"
          />
          <.see_more_card path={~p"/browse/movies"} type={:movies} class="hidden sm:flex" />
        </div>
      </.carousel_arrows>
    </div>
    """
  end

  # AI-Powered Series Section with Filters
  def render_ai_series_section(assigns) do
    assigns = assign_new(assigns, :progress_map, fn -> %{} end)

    ~H"""
    <div class="px-[4%]">
      <.section_header
        title="Séries Populares"
        icon="hero-tv-solid"
        icon_class="text-purple-500"
        genre_filters={@genre_filters}
        selected_genre={@selected_genre}
        on_genre_change="filter_series_genre"
        see_more_path={~p"/browse/series"}
        ai_powered={@ai_powered}
      />
      <.carousel_arrows id="carousel-series">
        <div
          data-carousel-track
          class="grid grid-cols-3 gap-2 sm:flex sm:gap-4 sm:overflow-x-auto py-1 sm:py-2 scrollbar-hide scroll-smooth"
        >
          <.render_series_card
            :for={series <- Enum.take(@items, 6)}
            series={series}
            progress={Map.get(@progress_map, series.id)}
            class="sm:hidden"
          />
          <.render_series_card
            :for={series <- @items}
            series={series}
            progress={Map.get(@progress_map, series.id)}
            class="hidden sm:block"
          />
          <.see_more_card path={~p"/browse/series"} type={:series} class="hidden sm:flex" />
        </div>
      </.carousel_arrows>
    </div>
    """
  end

  # AI-Powered Channels Section with Filters
  def render_ai_channels_section(assigns) do
    ~H"""
    <div class="px-[4%]">
      <.section_header
        title="TV ao Vivo"
        icon="hero-signal-solid"
        icon_class="text-red-500"
        genre_filters={@category_filters}
        selected_genre={@selected_category}
        on_genre_change="filter_channels_category"
        see_more_path={~p"/browse"}
        ai_powered={@ai_powered}
      />
      <.carousel_arrows id="carousel-channels">
        <div
          data-carousel-track
          class="grid grid-cols-3 gap-2 sm:grid-cols-none sm:grid-rows-2 sm:grid-flow-col sm:gap-4 sm:overflow-x-auto py-1 sm:py-2 scrollbar-hide scroll-smooth sm:auto-cols-[220px] lg:auto-cols-[280px]"
        >
          <.channel_card
            :for={channel <- Enum.take(@items, 6)}
            channel={channel}
            class="sm:hidden"
          />
          <.channel_card :for={channel <- @items} channel={channel} class="hidden sm:block" />
          <.see_more_card path={~p"/browse"} type={:channels} class="hidden sm:flex" />
        </div>
      </.carousel_arrows>
    </div>
    """
  end

  # Top 10 Component (Netflix-style with numbers)
  def render_top_10(assigns) do
    ~H"""
    <div class="px-[4%]">
      <div class="flex items-center justify-between mb-3 sm:mb-4">
        <h2 class="text-base sm:text-xl font-semibold text-text-primary flex items-center gap-2">
          <.icon name="hero-trophy" class="size-5 text-yellow-500" />
          {@title}
        </h2>
        <.link
          navigate={~p"/browse/movies"}
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

  # Top 10 Card with big number
  def top_10_card(assigns) do
    ~H"""
    <.link
      navigate={~p"/browse/movies/#{@movie.id}"}
      class="group flex-shrink-0 relative"
    >
      <div class="flex items-end">
        <!-- Big Number -->
        <div class="relative z-10 -mr-4 sm:-mr-6">
          <span class={[
            "text-[80px] sm:text-[120px] font-black leading-none",
            "bg-gradient-to-b from-text-primary to-text-muted bg-clip-text text-transparent",
            "drop-shadow-[0_2px_2px_rgba(0,0,0,0.8)]",
            @rank == 1 && "from-yellow-400 to-yellow-600",
            @rank == 2 && "from-gray-300 to-gray-500",
            @rank == 3 && "from-amber-600 to-amber-800"
          ]}>
            {@rank}
          </span>
        </div>
        <div class="w-[100px] sm:w-[140px] rounded-lg overflow-hidden bg-surface-hover shadow-lg transition-all group-hover:-translate-y-1 group-hover:shadow-xl group-hover:shadow-yellow-500/20">
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
                <span class="text-[9px] text-text-muted leading-tight line-clamp-2">
                  {@movie.name}
                </span>
              </div>
            </div>
            <!-- Hover overlay -->
            <div class="absolute inset-0 bg-black/30 opacity-0 group-hover:opacity-100 transition-opacity duration-200 hidden sm:flex items-center justify-center">
              <.icon name="hero-play-circle-solid" class="size-10 text-white/90 drop-shadow-lg" />
            </div>
            <!-- Rating badge -->
            <div
              :if={@movie.rating}
              class="absolute top-1 right-1 flex items-center gap-0.5 px-1 py-0.5 bg-black/70 rounded text-[10px] text-white"
            >
              <.icon name="hero-star-solid" class="size-2.5 text-yellow-500" />
              {Float.round(Decimal.to_float(@movie.rating), 1)}
            </div>
          </div>
        </div>
      </div>
    </.link>
    """
  end

  # See More Card at the end of carousel
  def see_more_card(assigns) do
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

  # Card Components
  def render_movie_card(assigns) do
    assigns = assigns |> assign_new(:class, fn -> nil end) |> assign_new(:progress, fn -> nil end)

    ~H"""
    <.link
      navigate={~p"/browse/movies/#{@movie.id}"}
      class={[
        "group flex-shrink-0 w-full sm:w-[180px] block transition-all duration-300 content-card",
        @class
      ]}
    >
      <div class="aspect-[2/3] bg-surface-hover relative rounded-md sm:rounded-lg overflow-hidden shadow-sm group-hover:shadow-xl group-hover:shadow-brand/20 transition-all duration-300 group-hover:-translate-y-1 block">
        <div id={"movie-img-#{@movie.id}"} phx-hook="ImageFallback" class="w-full h-full">
          <img
            :if={@movie.stream_icon}
            src={ImageProxy.proxy(@movie.stream_icon)}
            alt={@movie.name}
            class="w-full h-full object-cover animate-fade-in"
            loading="lazy"
            data-fallback-target
          />
          <div
            data-fallback
            class={[
              "w-full h-full flex flex-col items-center justify-center bg-gradient-to-br from-zinc-800 to-zinc-900 p-3 text-center",
              @movie.stream_icon && "hidden"
            ]}
          >
            <.icon name="hero-film" class="size-8 sm:size-10 text-brand/60 mb-2" />
            <span class="text-[10px] sm:text-xs text-text-muted leading-tight line-clamp-3">
              {@movie.name}
            </span>
          </div>
        </div>
        <!-- Hover overlay (hidden on touch devices) -->
        <div class="absolute inset-0 bg-black/30 opacity-0 group-hover:opacity-100 transition-opacity duration-200 hidden sm:flex items-center justify-center">
          <.icon name="hero-play-circle-solid" class="size-10 text-white/90 drop-shadow-lg" />
        </div>
        <!-- Rating badge -->
        <div
          :if={@movie.rating}
          class="absolute top-1 right-1 sm:top-2 sm:right-2 flex items-center gap-0.5 sm:gap-1 px-1 sm:px-1.5 py-0.5 bg-black/70 rounded text-[10px] sm:text-xs text-white"
        >
          <.icon name="hero-star-solid" class="size-2.5 sm:size-3 text-yellow-500" />
          {Float.round(Decimal.to_float(@movie.rating), 1)}
        </div>
        <!-- Progress bar -->
        <div :if={@progress && @progress > 0} class="absolute bottom-0 left-0 right-0 h-1 bg-zinc-700">
          <div class="h-full bg-brand rounded-r-full" style={"width: #{round(@progress * 100)}%"} />
        </div>
      </div>
      <div class="pt-1.5 sm:pt-2 px-0.5">
        <h3 class="text-xs sm:text-sm font-medium text-text-primary truncate group-hover:text-brand transition-colors">
          {@movie.title || @movie.name}
        </h3>
        <p class="text-[10px] sm:text-xs text-text-muted">{@movie.year}</p>
      </div>
    </.link>
    """
  end

  def render_series_card(assigns) do
    assigns = assigns |> assign_new(:class, fn -> nil end) |> assign_new(:progress, fn -> nil end)

    ~H"""
    <.link
      navigate={~p"/browse/series/#{@series.id}"}
      class={[
        "group flex-shrink-0 w-full sm:w-[180px] block transition-all duration-300 content-card",
        @class
      ]}
    >
      <div class="aspect-[2/3] bg-surface-hover relative rounded-md sm:rounded-lg overflow-hidden shadow-sm group-hover:shadow-xl group-hover:shadow-brand/20 transition-all duration-300 group-hover:-translate-y-1 block">
        <div id={"series-img-#{@series.id}"} phx-hook="ImageFallback" class="w-full h-full">
          <img
            :if={@series.cover}
            src={ImageProxy.proxy(@series.cover)}
            alt={@series.name}
            class="w-full h-full object-cover animate-fade-in"
            loading="lazy"
            data-fallback-target
          />
          <div
            data-fallback
            class={[
              "w-full h-full flex flex-col items-center justify-center bg-gradient-to-br from-zinc-800 to-zinc-900 p-3 text-center",
              @series.cover && "hidden"
            ]}
          >
            <.icon name="hero-tv" class="size-8 sm:size-10 text-brand/60 mb-2" />
            <span class="text-[10px] sm:text-xs text-text-muted leading-tight line-clamp-3">
              {@series.name}
            </span>
          </div>
        </div>
        <!-- Hover overlay (hidden on touch devices) -->
        <div class="absolute inset-0 bg-black/30 opacity-0 group-hover:opacity-100 transition-opacity duration-200 hidden sm:flex items-center justify-center">
          <.icon name="hero-play-circle-solid" class="size-10 text-white/90 drop-shadow-lg" />
        </div>
        <!-- Rating badge -->
        <div
          :if={@series.rating}
          class="absolute top-1 right-1 sm:top-2 sm:right-2 flex items-center gap-0.5 sm:gap-1 px-1 sm:px-1.5 py-0.5 bg-black/70 rounded text-[10px] sm:text-xs text-white"
        >
          <.icon name="hero-star-solid" class="size-2.5 sm:size-3 text-yellow-500" />
          {Float.round(Decimal.to_float(@series.rating), 1)}
        </div>
        <!-- Progress bar -->
        <div :if={@progress && @progress > 0} class="absolute bottom-0 left-0 right-0 h-1 bg-zinc-700">
          <div class="h-full bg-brand rounded-r-full" style={"width: #{round(@progress * 100)}%"} />
        </div>
      </div>
      <div class="pt-1.5 sm:pt-2 px-0.5">
        <h3 class="text-xs sm:text-sm font-medium text-text-primary truncate group-hover:text-brand transition-colors">
          {@series.title || @series.name}
        </h3>
        <p class="text-[10px] sm:text-xs text-text-muted">
          {@series.year}
        </p>
      </div>
    </.link>
    """
  end

  def channel_card(assigns) do
    assigns = assign_new(assigns, :class, fn -> nil end)

    ~H"""
    <.link
      navigate={~p"/watch/live_channel/#{@channel.id}"}
      class={[
        "group block transition-all duration-300 content-card w-full sm:w-[220px] lg:w-[280px]",
        @class
      ]}
    >
      <div class="aspect-video bg-surface-hover relative flex items-center justify-center rounded-md sm:rounded-lg overflow-hidden shadow-sm group-hover:shadow-xl group-hover:shadow-brand/20 transition-all duration-300 group-hover:-translate-y-1">
        <div id={"home-ch-img-#{@channel.id}"} phx-hook="ImageFallback" class="w-full h-full">
          <img
            :if={@channel.stream_icon not in [nil, ""]}
            src={ImageProxy.proxy(@channel.stream_icon)}
            alt={@channel.name}
            class="w-full h-full object-contain p-1.5 sm:p-2 animate-fade-in"
            loading="lazy"
            data-fallback-target
          />
          <div
            data-fallback
            class={[
              "w-full h-full flex flex-col items-center justify-center bg-gradient-to-br from-zinc-800 to-zinc-900 p-2 text-center",
              @channel.stream_icon not in [nil, ""] && "hidden"
            ]}
          >
            <.icon name="hero-tv" class="size-5 sm:size-8 text-brand/60 mb-1" />
            <span class="text-[8px] sm:text-xs text-text-muted leading-tight line-clamp-2">
              {@channel.name}
            </span>
          </div>
        </div>
        <!-- Live badge -->
        <div class="absolute top-1 left-1 sm:top-2 sm:left-2 flex items-center gap-0.5 sm:gap-1 px-1 sm:px-1.5 py-0.5 bg-brand rounded text-[8px] sm:text-xs text-white font-semibold">
          <span class="w-1 h-1 sm:w-1.5 sm:h-1.5 bg-white rounded-full animate-pulse" /> AO VIVO
        </div>
        <!-- Hover overlay (hidden on touch devices) -->
        <div class="absolute inset-0 bg-black/30 opacity-0 group-hover:opacity-100 transition-opacity duration-200 hidden sm:flex items-center justify-center">
          <.icon name="hero-play-solid" class="size-8 text-white/90 drop-shadow-lg" />
        </div>
      </div>
      <div class="pt-1.5 sm:pt-2 px-0.5">
        <h3 class="text-[11px] sm:text-sm font-medium text-text-primary truncate group-hover:text-brand transition-colors mt-0.5">
          {@channel.name}
        </h3>
      </div>
    </.link>
    """
  end

  def history_item(assigns) do
    assigns = assign_new(assigns, :class, fn -> nil end)

    ~H"""
    <.link
      navigate={watch_path(@entry.content_type, @entry.content_id)}
      class={[
        "group flex-shrink-0 w-full sm:w-[280px] block transition-all duration-300",
        @class
      ]}
    >
      <div class="aspect-video bg-surface-hover relative flex items-center justify-center rounded-md sm:rounded-lg overflow-hidden shadow-sm group-hover:shadow-xl group-hover:shadow-brand/20 transition-all duration-300 group-hover:-translate-y-1">
        <div id={"history-img-#{@entry.id}"} phx-hook="ImageFallback" class="w-full h-full">
          <img
            :if={@entry.content_icon}
            src={ImageProxy.proxy(@entry.content_icon)}
            alt={@entry.content_name}
            class="w-full h-full object-cover"
            loading="lazy"
            data-fallback-target
          />
          <div
            data-fallback
            class={[
              "w-full h-full flex items-center justify-center text-text-muted",
              @entry.content_icon && "hidden"
            ]}
          >
            <.icon name={content_type_icon(@entry.content_type)} class="size-8 sm:size-12" />
          </div>
        </div>
        <!-- Progress bar -->
        <div
          :if={@entry.progress_seconds && @entry.duration_seconds}
          class="absolute bottom-0 left-0 right-0 h-1 bg-white/30"
        >
          <div class="h-full bg-brand" style={"width: #{progress_percent(@entry)}%"} />
        </div>
        <!-- Hover overlay (hidden on touch devices) -->
        <div class="absolute inset-0 bg-black/30 opacity-0 group-hover:opacity-100 transition-opacity duration-200 hidden sm:flex items-center justify-center">
          <.icon name="hero-play-solid" class="size-8 text-white/90 drop-shadow-lg" />
        </div>
      </div>
      <div class="pt-2 px-0.5">
        <h3 class="text-xs sm:text-sm font-medium text-text-primary truncate group-hover:text-brand transition-colors">
          {@entry.content_name || "Desconhecido"}
        </h3>
        <p class="text-[10px] sm:text-xs text-text-muted flex items-center gap-1 sm:gap-2 mt-1">
          <span class="px-1 sm:px-1.5 py-0.5 rounded bg-surface-hover text-text-secondary">
            {format_content_type(@entry.content_type)}
          </span>
          <span>{format_relative_time(@entry.watched_at)}</span>
        </p>
      </div>
    </.link>
    """
  end

  def favorite_item(assigns) do
    assigns = assign_new(assigns, :class, fn -> nil end)

    ~H"""
    <.link
      navigate={watch_path(@favorite.content_type, @favorite.content_id)}
      class={[
        "group flex-shrink-0 w-full sm:w-[120px] rounded-lg overflow-hidden bg-surface content-card transition-transform duration-300 hover:-translate-y-1",
        @class
      ]}
    >
      <div class="aspect-[2/3] bg-surface-hover relative flex items-center justify-center">
        <div
          id={"fav-img-#{@favorite.content_type}-#{@favorite.content_id}"}
          phx-hook="ImageFallback"
          class="w-full h-full"
        >
          <img
            :if={@favorite.content_icon}
            src={ImageProxy.proxy(@favorite.content_icon)}
            alt={@favorite.content_name}
            class="w-full h-full object-cover"
            loading="lazy"
            data-fallback-target
          />
          <div
            data-fallback
            class={[
              "w-full h-full flex items-center justify-center text-text-muted",
              @favorite.content_icon && "hidden"
            ]}
          >
            <.icon name={content_type_icon(@favorite.content_type)} class="size-6 sm:size-10" />
          </div>
        </div>
        <!-- Hover overlay (hidden on touch devices) -->
        <div class="absolute inset-0 bg-black/30 opacity-0 group-hover:opacity-100 transition-opacity duration-200 hidden sm:flex items-center justify-center">
          <.icon name="hero-play-solid" class="size-8 text-white/90 drop-shadow-lg" />
        </div>
      </div>
    </.link>
    """
  end

  # Helper functions
  def get_backdrop(content) do
    # Use hero size (w1280) for large backgrounds - Netflix pattern
    case backdrop_urls(content) do
      [first | _] -> ImageProxy.hero(first)
      _ -> nil
    end
  end

  def backdrop_urls(%Iptv.Movie{} = m), do: Iptv.Movie.backdrop_urls(m)
  def backdrop_urls(%Iptv.Series{} = s), do: Iptv.Series.backdrop_urls(s)
  def backdrop_urls(_), do: []

  def content_path(:movie, movie), do: ~p"/watch/movie/#{movie.id}"
  def content_path(:series, series), do: ~p"/browse/series/#{series.id}"

  def content_info_path(:movie, movie), do: ~p"/browse/movies/#{movie.id}"
  def content_info_path(:series, series), do: ~p"/browse/series/#{series.id}"

  def watch_path("live_channel", id), do: ~p"/watch/live_channel/#{id}"
  def watch_path("live", id), do: ~p"/watch/live_channel/#{id}"
  def watch_path("movie", id), do: ~p"/watch/movie/#{id}"
  def watch_path("episode", id), do: ~p"/watch/episode/#{id}"
  def watch_path(_, id), do: ~p"/watch/movie/#{id}"

  def content_type_icon("live"), do: "hero-tv"
  def content_type_icon("movie"), do: "hero-film"
  def content_type_icon("series"), do: "hero-video-camera"
  def content_type_icon("episode"), do: "hero-play"
  def content_type_icon(_), do: "hero-film"

  def format_content_type("live"), do: "TV"
  def format_content_type("movie"), do: "Filme"
  def format_content_type("series"), do: "Série"
  def format_content_type("episode"), do: "Episódio"
  def format_content_type(_), do: "Vídeo"

  def progress_percent(%{progress_seconds: progress, duration_seconds: duration})
      when is_number(progress) and is_number(duration) and duration > 0 do
    min(round(progress / duration * 100), 100)
  end

  def progress_percent(_), do: 0

  def format_relative_time(nil), do: ""

  def format_relative_time(datetime) do
    now = DateTime.utc_now()
    diff = DateTime.diff(now, datetime, :second)

    cond do
      diff < 60 -> "agora"
      diff < 3600 -> "há #{div(diff, 60)} min"
      diff < 86_400 -> "há #{div(diff, 3600)} h"
      diff < 604_800 -> "há #{div(diff, 86_400)} dias"
      true -> Calendar.strftime(datetime, "%d/%m")
    end
  end

  # Get the "See More" path based on content type
  def get_see_more_path(:movies, _), do: ~p"/browse/movies"
  def get_see_more_path(:series, _), do: ~p"/browse/series"
  def get_see_more_path(:channels, _), do: ~p"/browse"
  def get_see_more_path(:history, _), do: ~p"/history"
  def get_see_more_path(:favorites, _), do: ~p"/favorites"
  def get_see_more_path(_, _), do: nil
end
