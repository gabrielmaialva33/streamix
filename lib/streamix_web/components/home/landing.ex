defmodule StreamixWeb.Home.Landing do
  @moduledoc """
  Public landing page components for the home surface.
  """

  use Phoenix.Component
  use StreamixWeb, :verified_routes

  import StreamixWeb.CoreComponents

  alias StreamixWeb.Helpers.ImageProxy

  def render_landing_page(assigns) do
    ~H"""
    <% featured = featured_content(@featured) %>
    <% hero_image = if featured, do: public_hero_image(featured) %>
    <div class="relative min-h-[52dvh] sm:min-h-[62dvh] overflow-hidden -mt-16 sm:-mt-20 pt-20 sm:pt-24">
      <%= if hero_image do %>
        <img
          src={hero_image}
          srcset={ImageProxy.srcset(hero_image, :hero)}
          sizes="100vw"
          alt=""
          class="absolute inset-0 w-full h-full object-cover object-top opacity-45"
          loading="eager"
          fetchpriority="high"
          decoding="async"
        />
      <% else %>
        <div class="absolute inset-0 auth-branded-bg" />
      <% end %>
      <div class="absolute inset-0 bg-gradient-to-t from-background via-background/75 to-black/45" />
      <div class="absolute inset-0 bg-gradient-to-r from-background via-background/40 to-transparent" />

      <div class="relative z-10 flex min-h-[calc(52dvh-5rem)] sm:min-h-[calc(62dvh-6rem)] items-end px-[4%] pb-8 sm:pb-12">
        <div class="max-w-4xl">
          <div class="mb-3 flex flex-wrap items-center gap-2 text-xs font-semibold uppercase tracking-normal text-white/70">
            <span class="rounded bg-brand px-2 py-1 text-white">Catálogo público</span>
            <span :if={featured} class="rounded bg-white/10 px-2 py-1">
              {featured_kind(@featured)} em destaque
            </span>
          </div>
          <h1 class="max-w-3xl text-3xl font-bold leading-tight text-white sm:text-5xl lg:text-6xl">
            Streamix aberto pra explorar filmes, séries e TV ao vivo
          </h1>
          <p class="mt-3 max-w-2xl text-sm leading-relaxed text-white/70 sm:mt-4 sm:text-lg">
            O catálogo global fica visível mesmo sem conta. A conta free libera progresso,
            favoritos e uma experiência mais personalizada quando você quiser.
          </p>

          <div class="mt-5 flex flex-col gap-3 sm:mt-7 sm:flex-row">
            <a
              href="#catalogo-publico"
              class="inline-flex min-h-11 items-center justify-center gap-2 rounded-md bg-white px-5 py-3 text-sm font-semibold text-black transition-colors hover:bg-white/90 sm:text-base"
            >
              <.icon name="hero-squares-2x2" class="size-5" /> Explorar catálogo
            </a>
            <.link
              href={~p"/register"}
              class="inline-flex min-h-11 items-center justify-center gap-2 rounded-md border border-white/15 bg-white/10 px-5 py-3 text-sm font-semibold text-white backdrop-blur-sm transition-colors hover:bg-white/20 sm:text-base"
            >
              <.icon name="hero-user-plus" class="size-5" /> Conta free
            </.link>
            <StreamixWeb.App.Pwa.install_action id="landing-pwa-install" variant="hero" />
          </div>
        </div>
      </div>
    </div>

    <section id="catalogo-publico" class="space-y-8 px-[4%] py-8 sm:space-y-10 sm:py-10">
      <div class="grid gap-3 sm:grid-cols-3">
        <.public_stat
          id="public-stat-movies"
          icon="hero-film"
          label="Filmes públicos"
          value={Map.get(@stats, :movies_count, 0)}
        />
        <.public_stat
          id="public-stat-series"
          icon="hero-tv"
          label="Séries públicas"
          value={Map.get(@stats, :series_count, 0)}
        />
        <.public_stat
          id="public-stat-channels"
          icon="hero-signal"
          label="Canais ao vivo"
          value={Map.get(@stats, :channels_count, 0)}
        />
      </div>

      <.public_media_shelf
        :if={@trending != []}
        id="public-trending"
        title="Em alta agora"
        icon="hero-fire-solid"
        items={@trending}
        kind={:movie}
      />

      <.public_media_shelf
        :if={@new_releases != []}
        id="public-new-releases"
        title="Lançamentos"
        icon="hero-sparkles"
        items={@new_releases}
        kind={:movie}
      />

      <.public_media_shelf
        :if={@movies != []}
        id="public-movies"
        title="Filmes públicos"
        icon="hero-film"
        items={@movies}
        kind={:movie}
      />

      <.public_media_shelf
        :if={@series != []}
        id="public-series"
        title="Séries públicas"
        icon="hero-tv"
        items={@series}
        kind={:series}
      />

      <.public_channel_shelf :if={@channels != []} channels={@channels} />

      <div
        :if={@movies == [] && @series == [] && @channels == []}
        class="rounded-lg border border-white/10 bg-surface/60 px-6 py-12 text-center"
      >
        <.icon name="hero-squares-2x2" class="mx-auto mb-3 size-10 text-text-muted" />
        <h2 class="text-xl font-semibold text-text-primary">Catálogo público vazio por enquanto</h2>
        <p class="mx-auto mt-2 max-w-md text-sm text-text-secondary">
          Assim que um provider global ou público tiver conteúdo sincronizado, ele aparece aqui sem exigir login.
        </p>
      </div>
    </section>

    <section class="border-t border-white/5 px-[4%] py-10 sm:py-12">
      <div class="flex flex-col gap-4 rounded-lg border border-white/10 bg-white/[0.04] p-5 sm:flex-row sm:items-center sm:justify-between sm:p-6">
        <div>
          <h2 class="text-lg font-semibold text-white">Quer salvar progresso e favoritos?</h2>
          <p class="mt-1 text-sm text-white/60">
            A conta free já entra com acesso ao catálogo global e deixa a experiência pronta pra personalização.
          </p>
        </div>
        <.link
          href={~p"/register"}
          class="inline-flex min-h-11 items-center justify-center gap-2 rounded-md bg-brand px-5 py-3 text-sm font-semibold text-white transition-colors hover:bg-brand-hover"
        >
          Criar conta free <.icon name="hero-arrow-right" class="size-4" />
        </.link>
      </div>
    </section>
    """
  end

  attr :id, :string, required: true
  attr :icon, :string, required: true
  attr :label, :string, required: true
  attr :value, :integer, required: true

  def public_stat(assigns) do
    ~H"""
    <div id={@id} class="rounded-lg border border-white/10 bg-white/[0.04] p-4">
      <div class="mb-3 flex size-10 items-center justify-center rounded-md bg-white/[0.06] text-white/80">
        <.icon name={@icon} class="size-5" />
      </div>
      <div class="text-2xl font-bold text-white">{@value}</div>
      <div class="mt-1 text-sm text-text-secondary">{@label}</div>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :icon, :string, required: true
  attr :items, :list, required: true
  attr :kind, :atom, required: true

  def public_media_shelf(assigns) do
    ~H"""
    <div id={@id} class="render-lazy">
      <div class="mb-3 flex items-center gap-2 sm:mb-4">
        <.icon name={@icon} class="size-5 text-brand" />
        <h2 class="text-base font-semibold text-text-primary sm:text-xl">{@title}</h2>
      </div>
      <div class="grid grid-cols-3 gap-2 sm:flex sm:gap-4 sm:overflow-x-auto sm:pb-2">
        <.public_media_card
          :for={{item, idx} <- Enum.with_index(@items)}
          item={item}
          kind={@kind}
          class={if idx >= 6, do: "hidden sm:block", else: ""}
        />
      </div>
    </div>
    """
  end

  attr :item, :map, required: true
  attr :kind, :atom, required: true
  attr :class, :string, default: nil

  def public_media_card(assigns) do
    assigns = assign(assigns, :image_url, public_card_image(assigns.item))

    ~H"""
    <article
      class={[
        "group w-full sm:w-[132px] lg:w-[148px] sm:flex-shrink-0",
        @class
      ]}
      title={public_title(@item)}
    >
      <div class="aspect-[2/3] overflow-hidden rounded-md bg-surface-hover shadow-sm transition-transform duration-300 group-hover:-translate-y-1 sm:rounded-lg">
        <div id={"public-#{@kind}-img-#{@item.id}"} phx-hook="ImageFallback" class="h-full w-full">
          <img
            :if={@image_url}
            src={@image_url}
            alt={public_title(@item)}
            class="h-full w-full object-cover"
            loading="lazy"
            decoding="async"
            data-fallback-target
          />
          <div
            data-fallback
            class={[
              "flex h-full w-full flex-col items-center justify-center bg-gradient-to-br from-zinc-800 to-zinc-900 p-2 text-center",
              @image_url && "hidden"
            ]}
          >
            <.icon
              name={if @kind == :series, do: "hero-tv", else: "hero-film"}
              class="mb-1 size-6 text-brand/60"
            />
            <span class="line-clamp-2 text-2xs leading-tight text-text-muted">
              {public_title(@item)}
            </span>
          </div>
        </div>
      </div>
      <div class="px-0.5 pt-1.5 sm:pt-2">
        <h3 class="line-clamp-2 text-2xs font-medium leading-tight text-text-primary sm:text-sm">
          {public_title(@item)}
        </h3>
        <p class="mt-1 flex items-center gap-1 text-2xs text-text-muted">
          <span :if={Map.get(@item, :year)}>{Map.get(@item, :year)}</span>
          <span :if={Map.get(@item, :rating)}>★ {public_rating(@item)}</span>
        </p>
      </div>
    </article>
    """
  end

  attr :channels, :list, required: true

  def public_channel_shelf(assigns) do
    ~H"""
    <div id="public-channels" class="render-lazy">
      <div class="mb-3 flex items-center gap-2 sm:mb-4">
        <.icon name="hero-signal-solid" class="size-5 text-brand" />
        <h2 class="text-base font-semibold text-text-primary sm:text-xl">TV ao vivo pública</h2>
      </div>
      <div class="grid grid-cols-3 gap-2 sm:grid-cols-none sm:grid-rows-2 sm:grid-flow-col sm:gap-4 sm:overflow-x-auto sm:pb-2 sm:auto-cols-[150px] lg:auto-cols-[176px]">
        <.public_channel_card
          :for={{channel, idx} <- Enum.with_index(@channels)}
          channel={channel}
          class={if idx >= 6, do: "hidden sm:block", else: ""}
        />
      </div>
    </div>
    """
  end

  attr :channel, :map, required: true
  attr :class, :string, default: nil

  def public_channel_card(assigns) do
    ~H"""
    <article class={["group w-full sm:w-[150px] lg:w-[176px]", @class]} title={@channel.name}>
      <div class="relative flex aspect-video items-center justify-center overflow-hidden rounded-md bg-surface-hover shadow-sm transition-transform duration-300 group-hover:-translate-y-1 sm:rounded-lg">
        <div id={"public-channel-img-#{@channel.id}"} phx-hook="ImageFallback" class="h-full w-full">
          <img
            :if={Map.get(@channel, :stream_icon) not in [nil, ""]}
            src={ImageProxy.proxy(@channel.stream_icon)}
            alt={@channel.name}
            class="h-full w-full object-contain p-1.5 sm:p-2"
            loading="lazy"
            decoding="async"
            data-fallback-target
          />
          <div
            data-fallback
            class={[
              "flex h-full w-full flex-col items-center justify-center bg-gradient-to-br from-zinc-800 to-zinc-900 p-2 text-center",
              Map.get(@channel, :stream_icon) not in [nil, ""] && "hidden"
            ]}
          >
            <.icon name="hero-tv" class="mb-1 size-5 text-brand/60 sm:size-8" />
            <span class="line-clamp-2 text-2xs leading-tight text-text-muted sm:text-xs">
              {@channel.name}
            </span>
          </div>
        </div>
        <div class="absolute left-1 top-1 flex items-center gap-1 rounded bg-brand px-1 py-0.5 text-2xs font-semibold text-white sm:left-2 sm:top-2 sm:px-1.5">
          <span class="size-1 rounded-full bg-white" /> AO VIVO
        </div>
      </div>
      <h3 class="mt-1.5 truncate px-0.5 text-2xs font-medium text-text-primary sm:mt-2 sm:text-sm">
        {@channel.name}
      </h3>
    </article>
    """
  end

  defp featured_content(nil), do: nil
  defp featured_content({_type, content}), do: content

  defp featured_kind({:movie, _content}), do: "Filme"
  defp featured_kind({:series, _content}), do: "Série"
  defp featured_kind(_), do: "Conteúdo"

  defp public_title(content), do: Map.get(content, :title) || Map.get(content, :name)

  defp public_hero_image(content) do
    url =
      Map.get(content, :backdrop) || Map.get(content, :cover) || Map.get(content, :stream_icon)

    if url in [nil, ""], do: nil, else: ImageProxy.poster(url, :hero_backdrop)
  end

  defp public_card_image(content) do
    url = Map.get(content, :stream_icon) || Map.get(content, :cover)
    if url in [nil, ""], do: nil, else: ImageProxy.poster(url, :carousel)
  end

  defp public_rating(content) do
    case Map.get(content, :rating) do
      nil -> nil
      %Decimal{} = rating -> rating |> Decimal.to_float() |> Float.round(1)
      rating when is_float(rating) -> Float.round(rating, 1)
      rating -> rating
    end
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
          gradient="from-info/15 to-surface"
        />
        <.feature_card
          icon="hero-server-stack"
          title="Múltiplos provedores"
          description="Conecte quantos provedores IPTV quiser e veja tudo em um catálogo unificado."
          gradient="from-accent/15 to-surface"
        />
        <.feature_card
          icon="hero-magnifying-glass"
          title="Busca inteligente"
          description="Encontre o que quer com busca semântica por IA. Pesquise por tema, clima ou descrição."
          gradient="from-success/15 to-surface"
        />
        <.feature_card
          icon="hero-users"
          title="Watch Party"
          description="Assista junto com amigos em tempo real, sincronizado e com chat ao vivo."
          gradient="from-brand/15 to-surface"
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
    <div class={"rounded-lg bg-gradient-to-br #{@gradient} border border-border p-6 sm:p-8"}>
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
end
