defmodule StreamixWeb.App.Pwa do
  @moduledoc """
  Install discovery and iOS home-screen guidance for the Streamix PWA.
  """

  use Phoenix.Component

  import StreamixWeb.CoreComponents, only: [icon: 1]

  attr :id, :string, required: true
  attr :variant, :string, values: ~w(hero settings), default: "settings"

  def install_action(assigns) do
    assigns =
      assign(
        assigns,
        :button_class,
        case assigns.variant do
          "hero" ->
            "border border-white/15 bg-white/10 px-5 py-3 text-white backdrop-blur-sm hover:bg-white/20 sm:text-base"

          "settings" ->
            "border border-brand/30 bg-brand/10 px-4 py-2 text-brand hover:bg-brand/20"
        end
      )

    ~H"""
    <div
      id={@id}
      phx-hook="PwaInstall"
      class={["w-full sm:w-auto", @variant == "settings" && "self-start"]}
    >
      <button
        type="button"
        data-pwa-install-action
        class={[
          "inline-flex min-h-11 w-full items-center justify-center gap-2 rounded-md text-sm font-semibold transition-colors disabled:cursor-wait disabled:opacity-70 sm:w-auto",
          @button_class
        ]}
      >
        <.icon name="hero-arrow-down-tray" class="size-5" />
        <span data-pwa-install-label>Instalar app</span>
      </button>

      <p data-pwa-install-status class="sr-only" aria-live="polite"></p>

      <div
        data-pwa-ios-dialog
        hidden
        role="dialog"
        aria-modal="true"
        aria-labelledby={"#{@id}-ios-title"}
        class="fixed inset-0 z-[10000]"
      >
        <button
          type="button"
          data-pwa-ios-close="backdrop"
          aria-label="Fechar instruções de instalação"
          class="absolute inset-0 size-full bg-black/75 backdrop-blur-sm"
        ></button>

        <div class="absolute inset-x-4 bottom-[calc(1rem+env(safe-area-inset-bottom))] mx-auto max-w-md rounded-xl border border-border bg-surface p-5 text-left shadow-2xl">
          <div class="flex items-start justify-between gap-4">
            <div>
              <h2
                id={"#{@id}-ios-title"}
                data-pwa-install-dialog-title
                class="text-lg font-semibold text-text-primary"
              >
                Adicionar o Streamix no iPhone
              </h2>
              <p class="mt-1 text-sm leading-6 text-text-secondary">
                No Safari, faça estes três passos:
              </p>
            </div>
            <button
              type="button"
              data-pwa-ios-close="button"
              aria-label="Fechar instruções"
              class="flex size-11 shrink-0 items-center justify-center rounded-md text-text-secondary transition-colors hover:bg-surface-hover hover:text-text-primary"
            >
              <.icon name="hero-x-mark" class="size-6" />
            </button>
          </div>

          <ol data-pwa-ios-steps class="mt-4 space-y-3 text-sm text-text-primary">
            <li class="flex items-center gap-3">
              <span class="flex size-8 shrink-0 items-center justify-center rounded-full bg-brand/15 font-semibold text-brand">
                1
              </span>
              Toque em <strong>Compartilhar</strong>
              <.icon name="hero-arrow-up-on-square" class="ml-auto size-5 text-brand" />
            </li>
            <li class="flex items-center gap-3">
              <span class="flex size-8 shrink-0 items-center justify-center rounded-full bg-brand/15 font-semibold text-brand">
                2
              </span>
              Escolha <strong>Adicionar à Tela de Início</strong>
            </li>
            <li class="flex items-center gap-3">
              <span class="flex size-8 shrink-0 items-center justify-center rounded-full bg-brand/15 font-semibold text-brand">
                3
              </span>
              Confirme em <strong>Adicionar</strong>
            </li>
          </ol>

          <div
            data-pwa-manual-steps
            hidden
            class="mt-4 space-y-3 text-sm leading-6 text-text-primary"
          >
            <p>
              Abra o menu do navegador e escolha <strong>Instalar app</strong>
              ou <strong>Adicionar à tela inicial</strong>.
            </p>
            <p class="text-text-secondary">
              Se a opção ainda não aparecer, mantenha esta página aberta por alguns segundos e
              tente novamente. O Streamix avisará assim que o instalador nativo estiver disponível.
            </p>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
