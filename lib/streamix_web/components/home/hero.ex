defmodule StreamixWeb.Home.Hero do
  @moduledoc """
  Hero components for the authenticated home page.
  """

  use Phoenix.Component
  use StreamixWeb, :verified_routes

  import StreamixWeb.CoreComponents
  import StreamixWeb.Home.Helpers

  def render_hero_section(assigns) do
    ~H"""
    <%!--
      iOS Safari: use dvh so the home hero doesn't resize awkwardly when the
      URL bar shows/hides while scrolling. max-h-[800px] keeps it sane on
      tablets in landscape.
    --%>
    <div class="relative h-[45dvh] sm:h-[60dvh] lg:h-[70dvh] min-h-[280px] sm:min-h-[400px] max-h-[800px] overflow-hidden -mt-16 sm:-mt-20 pt-14 sm:pt-16">
      <%= if @featured do %>
        <.hero_background featured={@featured} />
      <% else %>
        <.hero_fallback />
      <% end %>

      <div class="absolute inset-0 bg-gradient-to-t from-background via-background/60 to-transparent" />
      <div class="absolute inset-0 bg-gradient-to-r from-background via-background/40 to-transparent" />

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

    assigns =
      assigns
      |> assign(:backdrop, get_backdrop(content))
      |> assign(:trailer_id, Map.get(content, :youtube_trailer))

    ~H"""
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
    <div
      :if={@trailer_id}
      id="hero-trailer-container"
      phx-hook=".HeroTrailer"
      data-trailer-id={@trailer_id}
      class="absolute inset-0 opacity-0 transition-opacity duration-1000 pointer-events-none"
    >
      <div id="hero-trailer-player" class="w-full h-full"></div>
    </div>
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

          if (window.innerWidth < 768) return

          if (!window.YT) {
            const tag = document.createElement('script')
            tag.src = 'https://www.youtube.com/iframe_api'
            document.head.appendChild(tag)
            window.onYouTubeIframeAPIReady = () => this.createPlayer()
          } else {
            this.createPlayer()
          }

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
          setTimeout(() => {
            this.el.style.opacity = '1'
            this.loaded = true
            const muteBtn = document.getElementById('hero-mute-toggle')
            if (muteBtn) muteBtn.style.opacity = '1'
          }, 500)

          this.timeout = setTimeout(() => this.fadeOut(), 40000)
        },

        onStateChange(event) {
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
    <div class="absolute inset-0 flex items-center justify-center">
      <div class="text-center px-6 max-w-lg">
        <div class="w-16 h-16 rounded-full bg-brand/10 flex items-center justify-center mx-auto mb-4">
          <.icon name="hero-play-solid" class="size-8 text-brand" />
        </div>
        <h2 class="text-2xl sm:text-3xl font-bold text-white mb-2">Bem-vindo ao Streamix</h2>
        <p class="text-text-secondary text-sm sm:text-base">
          Explore filmes, séries e TV ao vivo dos seus provedores.
        </p>
      </div>
    </div>
    """
  end

  def hero_content(assigns) do
    {type, content} = assigns.featured
    assigns = assign(assigns, :type, type) |> assign(:content, content)

    ~H"""
    <div class="max-w-2xl animate-slide-up">
      <div class="flex items-center gap-2 mb-4">
        <span class="px-2 py-1 text-xs font-semibold bg-brand text-white rounded">
          {if @type == :movie, do: "FILME", else: "SÉRIE"}
        </span>
        <span :if={@content.rating} class="flex items-center gap-1 text-sm text-text-secondary">
          <.icon name="hero-star-solid" class="size-4 text-warning" />
          {Float.round(Decimal.to_float(@content.rating), 1)}
        </span>
        <span :if={@content.year} class="text-sm text-text-secondary">
          {@content.year}
        </span>
        <span :if={@content.genres != []} class="text-sm text-text-secondary">
          {List.first(@content.genres).name}
        </span>
      </div>

      <h1 class="text-2xl sm:text-4xl md:text-6xl font-bold text-text-primary mb-2 sm:mb-4 drop-shadow-lg">
        {@content.title || @content.name}
      </h1>

      <p
        :if={@content.plot}
        class="hidden sm:block text-base sm:text-lg text-text-secondary mb-4 sm:mb-6 line-clamp-2 sm:line-clamp-3 max-w-xl"
      >
        {@content.plot}
      </p>

      <div class="flex gap-2 sm:gap-3">
        <.link
          href={content_path(@type, @content)}
          class="inline-flex items-center gap-1.5 sm:gap-2 px-4 sm:px-8 py-2 sm:py-3 bg-white text-black text-sm sm:text-base font-semibold rounded-md hover:bg-white/90 transition-colors"
        >
          <.icon name="hero-play-solid" class="size-4 sm:size-6" /> Assistir
        </.link>
        <.link
          href={content_info_path(@type, @content)}
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
end
