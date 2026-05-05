defmodule StreamixWeb.Home.Landing do
  @moduledoc """
  Public landing page components for the home surface.
  """

  use Phoenix.Component
  use StreamixWeb, :verified_routes

  import StreamixWeb.CoreComponents
  import StreamixWeb.Home.Carousel

  def render_landing_page(assigns) do
    ~H"""
    <div class="relative min-h-[95dvh] flex items-center justify-center overflow-hidden -mt-16 sm:-mt-20">
      <div class="absolute inset-0 auth-branded-bg" />
      <div class="absolute inset-0 bg-gradient-to-t from-background via-background/60 to-black/40" />
      <div class="absolute inset-0 bg-gradient-to-b from-black/70 via-transparent to-transparent h-32" />
      <div class="absolute inset-0 bg-gradient-to-r from-background via-transparent to-background" />

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

    <div :if={@top_10 != []} class="relative z-10 -mt-16 pb-8">
      <.render_top_10 title="Em alta no Streamix" items={@top_10} />
    </div>

    <.landing_features />

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

    <.landing_faq />

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
