defmodule StreamixWeb.TvLive do
  @moduledoc """
  Página pública de download do app Streamix TV.

  Apresenta os instaladores publicados em
  https://github.com/gabrielmaialva33/streamix-tv/releases e o passo-a-passo
  de instalação para Android TV / Fire TV (sideload via Downloader) e
  Samsung Tizen (Developer Mode + sdb).
  """
  use StreamixWeb, :live_view

  @release_tag "v1.0.000"
  @release_url "https://github.com/gabrielmaialva33/streamix-tv/releases/tag/v1.0.000"
  @apk_url "https://github.com/gabrielmaialva33/streamix-tv/releases/download/v1.0.000/Streamix-v1.0.000.apk"
  @apk_size_mb "7.3"
  @apk_sha256 "5b3f503c8c7ffc4eb99905defa2093d3f412482aaaf25026216143270a75f1cd"
  @wgt_url "https://github.com/gabrielmaialva33/streamix-tv/releases/download/v1.0.000/Streamix-v1.0.000.wgt"
  @wgt_size_mb "3.1"
  @wgt_sha256 "bbdc5e9592b5b1a17c6783fa80e3176c61ef22f977c8ba7860f032afe11dd83d"

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(page_title: "Baixar Streamix TV")
      |> assign(current_path: "/tv")
      |> assign(release_tag: @release_tag)
      |> assign(release_url: @release_url)
      |> assign(apk_url: @apk_url)
      |> assign(apk_size_mb: @apk_size_mb)
      |> assign(apk_sha256: @apk_sha256)
      |> assign(wgt_url: @wgt_url)
      |> assign(wgt_size_mb: @wgt_size_mb)
      |> assign(wgt_sha256: @wgt_sha256)
      |> assign(active_tab: "android")

    {:ok, socket}
  end

  @impl true
  def handle_event("set-tab", %{"tab" => tab}, socket) when tab in ["android", "tizen"] do
    {:noreply, assign(socket, active_tab: tab)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-5xl py-10 sm:py-16">
      <%!-- Hero --%>
      <section class="text-center space-y-4">
        <span class="inline-flex items-center gap-2 rounded-full bg-brand/10 px-3 py-1 text-xs font-medium text-brand">
          <.icon name="hero-sparkles" class="size-3.5" /> Beta {@release_tag}
        </span>
        <h1 class="text-4xl sm:text-5xl font-bold text-text-primary tracking-tight">
          Streamix TV
        </h1>
        <p class="text-lg text-text-secondary max-w-2xl mx-auto">
          App nativo de TV pra assistir todo o catálogo do Streamix direto no Android TV, Fire TV e Samsung Smart TV (Tizen). Sem PWA, sem browser — UI feita pro controle remoto.
        </p>
        <div class="flex flex-wrap items-center justify-center gap-3 pt-2 text-sm text-text-muted">
          <span class="flex items-center gap-1.5">
            <.icon name="hero-tv" class="size-4" /> Android TV 5.0+ / Fire OS
          </span>
          <span class="text-text-muted/40">•</span>
          <span class="flex items-center gap-1.5">
            <.icon name="hero-tv" class="size-4" /> Samsung Tizen 5.5+
          </span>
          <span class="text-text-muted/40">•</span>
          <.link
            href={@release_url}
            target="_blank"
            rel="noopener"
            class="flex items-center gap-1.5 text-brand hover:underline"
          >
            <.icon name="hero-arrow-top-right-on-square" class="size-4" /> Release no GitHub
          </.link>
        </div>
      </section>

      <%!-- Download cards --%>
      <section class="grid gap-4 sm:grid-cols-2 mt-12">
        <.download_card
          platform="Android TV / Fire TV"
          icon="hero-device-tablet"
          format="APK"
          size={@apk_size_mb}
          sha256={@apk_sha256}
          url={@apk_url}
          filename={"Streamix-#{@release_tag}.apk"}
          accent="from-emerald-500/20 to-emerald-500/0"
        />
        <.download_card
          platform="Samsung Smart TV (Tizen)"
          icon="hero-tv"
          format="WGT"
          size={@wgt_size_mb}
          sha256={@wgt_sha256}
          url={@wgt_url}
          filename={"Streamix-#{@release_tag}.wgt"}
          accent="from-sky-500/20 to-sky-500/0"
        />
      </section>

      <%!-- Tabs --%>
      <section class="mt-16">
        <h2 class="text-2xl sm:text-3xl font-bold text-text-primary mb-2">
          Como instalar
        </h2>
        <p class="text-text-secondary mb-6">
          Escolhe a plataforma e segue o passo-a-passo. Demora uns 5 minutos.
        </p>

        <div role="tablist" class="flex gap-1 bg-surface-hover/40 p-1 rounded-xl w-fit mb-6">
          <button
            type="button"
            role="tab"
            aria-selected={@active_tab == "android"}
            phx-click="set-tab"
            phx-value-tab="android"
            class={[
              "px-4 py-2 text-sm font-medium rounded-lg transition-all",
              if(@active_tab == "android",
                do: "bg-brand text-white shadow-sm",
                else: "text-text-secondary hover:text-text-primary"
              )
            ]}
          >
            Android TV / Fire TV
          </button>
          <button
            type="button"
            role="tab"
            aria-selected={@active_tab == "tizen"}
            phx-click="set-tab"
            phx-value-tab="tizen"
            class={[
              "px-4 py-2 text-sm font-medium rounded-lg transition-all",
              if(@active_tab == "tizen",
                do: "bg-brand text-white shadow-sm",
                else: "text-text-secondary hover:text-text-primary"
              )
            ]}
          >
            Samsung Tizen
          </button>
        </div>

        <%= if @active_tab == "android" do %>
          <.android_tutorial apk_url={@apk_url} />
        <% else %>
          <.tizen_tutorial wgt_url={@wgt_url} />
        <% end %>
      </section>

      <%!-- FAQ / footer notes --%>
      <section class="mt-16 grid gap-6 sm:grid-cols-2">
        <.note title="Versão beta" icon="hero-beaker">
          v1.0.000 é a primeira release pública. Bugs e regressões são esperados — abre uma issue no
          <.link
            href="https://github.com/gabrielmaialva33/streamix-tv/issues"
            target="_blank"
            rel="noopener"
            class="text-brand hover:underline"
          >
            repositório
          </.link>
          se algo travar.
        </.note>
        <.note title="Atualizações" icon="hero-arrow-path">
          O app não tem auto-update ainda. Quando sair v1.1, baixa o novo arquivo aqui e reinstala por cima — login e histórico ficam preservados.
        </.note>
        <.note title="Verificar integridade (opcional)" icon="hero-shield-check">
          Cada release tem hash SHA-256 listado nos cards acima. Em Linux/macOS:
          <code class="block bg-surface px-2 py-1 rounded text-xs mt-2 overflow-x-auto">
            sha256sum Streamix-{@release_tag}.apk
          </code>
        </.note>
        <.note title="Sem APK em LG / Roku" icon="hero-information-circle">
          Por enquanto só Android TV / Fire TV (.apk) e Samsung Tizen (.wgt). LG webOS e Roku ainda não têm build oficial — fica de olho no GitHub.
        </.note>
      </section>
    </div>
    """
  end

  attr :platform, :string, required: true
  attr :icon, :string, required: true
  attr :format, :string, required: true
  attr :size, :string, required: true
  attr :sha256, :string, required: true
  attr :url, :string, required: true
  attr :filename, :string, required: true
  attr :accent, :string, required: true

  defp download_card(assigns) do
    ~H"""
    <div class={[
      "relative overflow-hidden rounded-2xl border border-border bg-surface p-6 transition-all hover:border-brand/40 hover:shadow-lg",
      "bg-gradient-to-br",
      @accent
    ]}>
      <div class="flex items-start justify-between">
        <div class="flex items-center gap-3">
          <div class="p-2.5 rounded-xl bg-surface-hover">
            <.icon name={@icon} class="size-6 text-text-primary" />
          </div>
          <div>
            <h3 class="font-semibold text-text-primary">{@platform}</h3>
            <p class="text-xs text-text-muted">{@format} • {@size} MB</p>
          </div>
        </div>
      </div>

      <div class="mt-5 space-y-3">
        <.link
          href={@url}
          class="flex items-center justify-center gap-2 w-full px-4 py-2.5 bg-brand hover:bg-brand-hover text-white font-medium rounded-xl transition-all shadow-sm hover:shadow-md"
          download={@filename}
        >
          <.icon name="hero-arrow-down-tray" class="size-4" /> Baixar {@format}
        </.link>
        <details class="group">
          <summary class="text-xs text-text-muted hover:text-text-secondary cursor-pointer list-none flex items-center gap-1">
            <.icon name="hero-chevron-right" class="size-3 group-open:rotate-90 transition-transform" />
            SHA-256
          </summary>
          <code class="block mt-2 text-[10px] text-text-muted bg-surface-hover/60 px-2 py-1.5 rounded break-all">
            {@sha256}
          </code>
        </details>
      </div>
    </div>
    """
  end

  attr :apk_url, :string, required: true

  defp android_tutorial(assigns) do
    ~H"""
    <div class="space-y-6">
      <.method_card
        number="A"
        title="Método 1 — Downloader app (recomendado)"
        subtitle="Direto no controle, sem PC. Funciona em Fire TV Stick, Fire TV Cube, Chromecast com Google TV, Nvidia Shield e qualquer Android TV."
      >
        <.step number="1" title="Instalar o Downloader">
          Na tela inicial da TV, abre a loja de apps, busca <strong>Downloader</strong>
          (autor: AFTVNews) e instala.
        </.step>
        <.step number="2" title="Habilitar Developer Options">
          Vai em <strong>Configurações → Dispositivo / Sobre</strong>
          e clica 7 vezes no nome do aparelho até aparecer "Você é desenvolvedor".
        </.step>
        <.step number="3" title="Permitir apps de origens desconhecidas">
          <strong>Configurações → Developer Options → Install Unknown Apps</strong>
          → liga a permissão pro Downloader.
        </.step>
        <.step number="4" title="Colar a URL do APK">
          Abre o Downloader, na aba <strong>Home</strong>
          cola exatamente:
          <code class="block bg-surface px-3 py-2 rounded mt-2 text-xs break-all">{@apk_url}</code>
          Ou usa o URL encurtado se preferir digitar pelo controle:
          <code class="text-brand">go.aftv/streamix</code>
          (em breve).
        </.step>
        <.step number="5" title="Instalar">
          O Downloader baixa o APK, abre a tela de instalação automaticamente. Clica
          <strong>Install</strong>
          e depois <strong>Done</strong>. Pode deletar o arquivo pra liberar espaço.
        </.step>
      </.method_card>

      <.method_card
        number="B"
        title="Método 2 — ADB pelo PC"
        subtitle="Pra quem prefere terminal. TV e PC na mesma rede Wi-Fi."
      >
        <.step number="1" title="Habilitar ADB Debugging">
          <strong>Configurações → Developer Options</strong>
          → liga <strong>ADB Debugging</strong>. Anota o IP da TV (em Rede / Sobre).
        </.step>
        <.step number="2" title="Conectar via ADB">
          No terminal do PC (Android Platform Tools instalado):
          <code class="block bg-surface px-3 py-2 rounded mt-2 text-xs">
            adb connect 192.168.x.x:5555
          </code>
          A TV vai pedir pra autorizar — aceita.
        </.step>
        <.step number="3" title="Instalar o APK">
          <code class="block bg-surface px-3 py-2 rounded mt-2 text-xs">
            adb install Streamix-v1.0.000.apk
          </code>
          Quando terminar com "Success", o app aparece na lista.
        </.step>
      </.method_card>

      <.method_card
        number="C"
        title="Método 3 — Send Files to TV"
        subtitle="Manda o APK do celular pra TV via Wi-Fi. Bom se já baixou pelo celular."
      >
        <.step number="1" title="Instalar nos dois dispositivos">
          App <strong>Send Files to TV</strong> na TV e no celular Android.
        </.step>
        <.step number="2" title="Receber na TV">
          Abre o app na TV, clica <strong>Receive</strong>.
        </.step>
        <.step number="3" title="Enviar do celular">
          No celular, clica <strong>Send</strong>, escolhe o APK baixado, seleciona a TV. Confirma a instalação na TV.
        </.step>
      </.method_card>

      <.callout kind="warning">
        <strong>Fire TV Stick 4K Select</strong>
        (Vega OS) não suporta sideload. Só Fire OS / Android-based.
      </.callout>
    </div>
    """
  end

  attr :wgt_url, :string, required: true

  defp tizen_tutorial(assigns) do
    ~H"""
    <div class="space-y-6">
      <.callout kind="info">
        Tizen exige instalar o <strong>Tizen Studio</strong>
        no PC e habilitar Developer Mode na TV. PC e TV precisam estar na mesma rede Wi-Fi.
      </.callout>

      <.method_card
        number="1"
        title="Instalar Tizen Studio no PC"
        subtitle="Disponível pra Windows, macOS e Linux."
      >
        <.step number="1.1" title="Baixar">
          Pega o <strong>Tizen Studio with IDE installer</strong>
          em
          <.link
            href="https://developer.tizen.org/development/tizen-studio/download"
            target="_blank"
            rel="noopener"
            class="text-brand hover:underline"
          >
            developer.tizen.org
          </.link>
          .
        </.step>
        <.step number="1.2" title="Instalar SDK + Extras">
          Quando abrir o <strong>Package Manager</strong>: aba <strong>Main SDK</strong>
          → instala <strong>Tizen SDK tools</strong>. Depois aba <strong>Extension SDK</strong>
          → instala <strong>Samsung Certificate Extension</strong>
          + <strong>TV Extensions</strong>.
        </.step>
        <.step number="1.3" title="Adicionar ao PATH (opcional)">
          Pra usar <code>sdb</code>
          e <code>tizen</code>
          de qualquer terminal, adiciona
          <code class="block bg-surface px-2 py-1 rounded text-xs mt-2">
            ~/tizen-studio/tools<br />~/tizen-studio/tools/ide/bin
          </code>
          ao seu PATH.
        </.step>
      </.method_card>

      <.method_card
        number="2"
        title="Habilitar Developer Mode na TV"
        subtitle="Modo escondido — segue o passo certinho."
      >
        <.step number="2.1" title="Abrir Apps">
          No controle da TV, aperta <strong>Home</strong> → vai pra <strong>Apps</strong>.
        </.step>
        <.step number="2.2" title="Código secreto">
          Aperta <strong>1 2 3 4 5</strong>
          no controle numérico (ou no teclado virtual). Aparece a tela de Developer Mode.
        </.step>
        <.step number="2.3" title="Liberar e colocar IP do PC">
          Liga <strong>Developer Mode: On</strong> → digita o IP do seu PC → confirma. A TV reinicia.
        </.step>
        <.step number="2.4" title="Anotar IP da TV">
          <strong>Configurações → Rede → Status de Conexão</strong> → anota o IP.
        </.step>
      </.method_card>

      <.method_card number="3" title="Criar perfil de certificado" subtitle="Tizen exige assinatura.">
        <.step number="3.1" title="Abrir Certificate Manager">
          No Tizen Studio: <strong>Tools → Certificate Manager → +</strong>.
        </.step>
        <.step number="3.2" title="Tipo Samsung">
          Escolhe <strong>Samsung</strong>
          → <strong>TV</strong>
          → <strong>Public</strong>. Faz login com sua conta Samsung.
        </.step>
        <.step number="3.3" title="Salvar e ativar">
          Dá um nome (ex: <code>streamix-cert</code>) → cria a senha → finaliza. Marca como ativo (✓).
        </.step>
      </.method_card>

      <.method_card
        number="4"
        title="Conectar via SDB e instalar"
        subtitle="Linha de comando direto na TV."
      >
        <.step number="4.1" title="Baixar o WGT">
          <.link
            href={@wgt_url}
            class="text-brand hover:underline"
          >
            Streamix-v1.0.000.wgt
          </.link>
          — salva em alguma pasta acessível (ex: <code>~/Downloads</code>).
        </.step>
        <.step number="4.2" title="Conectar à TV">
          <code class="block bg-surface px-3 py-2 rounded mt-2 text-xs">
            sdb connect 192.168.x.x<br />sdb devices
          </code>
          A TV deve aparecer na lista.
        </.step>
        <.step number="4.3" title="Permitir instalação">
          No Tizen Studio: <strong>Tools → Device Manager</strong>
          → clica direito no device → <strong>Permit to install applications</strong>.
        </.step>
        <.step number="4.4" title="Instalar">
          <code class="block bg-surface px-3 py-2 rounded mt-2 text-xs">
            tizen install -n ~/Downloads/Streamix-v1.0.000.wgt -t 192.168.x.x:26101
          </code>
          Pode parecer que falhou no final ("installation failed") — mas é falso positivo, o app já tá lá. Abre a lista de apps da TV e confirma.
        </.step>
      </.method_card>

      <.callout kind="info">
        Em vez de CLI, dá pra usar o <strong>GUI do Tizen Studio</strong>: File → Import → Tizen Project → Archive file → seleciona o .wgt → Profile:
        <code>tv-samsung</code>
        → Finish → botão direito no projeto → Run As → Tizen Web Application.
      </.callout>
    </div>
    """
  end

  attr :number, :string, required: true
  attr :title, :string, required: true
  attr :subtitle, :string, default: nil
  slot :inner_block, required: true

  defp method_card(assigns) do
    ~H"""
    <div class="rounded-2xl border border-border bg-surface overflow-hidden">
      <div class="px-6 py-4 border-b border-border bg-surface-hover/30">
        <div class="flex items-baseline gap-3">
          <span class="text-2xl font-bold text-brand">{@number}</span>
          <div>
            <h3 class="font-semibold text-text-primary">{@title}</h3>
            <p :if={@subtitle} class="text-sm text-text-muted mt-0.5">{@subtitle}</p>
          </div>
        </div>
      </div>
      <ol class="px-6 py-5 space-y-4">
        {render_slot(@inner_block)}
      </ol>
    </div>
    """
  end

  attr :number, :string, required: true
  attr :title, :string, required: true
  slot :inner_block, required: true

  defp step(assigns) do
    ~H"""
    <li class="flex gap-4">
      <span class="shrink-0 size-7 rounded-full bg-brand/10 text-brand text-xs font-bold flex items-center justify-center">
        {@number}
      </span>
      <div class="flex-1 pt-0.5">
        <p class="font-medium text-text-primary mb-1">{@title}</p>
        <div class="text-sm text-text-secondary space-y-1">{render_slot(@inner_block)}</div>
      </div>
    </li>
    """
  end

  attr :kind, :string, default: "info", values: ["info", "warning"]
  slot :inner_block, required: true

  defp callout(assigns) do
    ~H"""
    <div class={[
      "rounded-xl border px-4 py-3 text-sm flex gap-3",
      case @kind do
        "warning" -> "border-warning/40 bg-warning/10 text-warning"
        _ -> "border-brand/30 bg-brand/5 text-text-secondary"
      end
    ]}>
      <.icon
        name={
          case @kind do
            "warning" -> "hero-exclamation-triangle"
            _ -> "hero-information-circle"
          end
        }
        class="size-5 shrink-0 mt-0.5"
      />
      <div>{render_slot(@inner_block)}</div>
    </div>
    """
  end

  attr :title, :string, required: true
  attr :icon, :string, required: true
  slot :inner_block, required: true

  defp note(assigns) do
    ~H"""
    <div class="rounded-xl border border-border bg-surface/50 p-4">
      <div class="flex items-center gap-2 mb-2">
        <.icon name={@icon} class="size-4 text-brand" />
        <h4 class="font-semibold text-text-primary text-sm">{@title}</h4>
      </div>
      <p class="text-sm text-text-secondary">{render_slot(@inner_block)}</p>
    </div>
    """
  end
end
