defmodule StreamixWeb.FooterComponents do
  @moduledoc """
  Site-wide footer component for Streamix.

  Uses pure Tailwind CSS v4 with the existing theme tokens
  (`text-text-*`, `border-border`, `bg-background`).
  """
  use Phoenix.Component
  use StreamixWeb, :verified_routes

  @doc """
  Renders the public application footer with nav links, version, and
  a lightweight copyright line.

  The footer is pure content — no JS, no LV events. It gates the
  "Admin" link on `current_scope.user` admin status when available.
  """
  attr :current_scope, :any, default: nil

  def app_footer(assigns) do
    assigns =
      assigns
      |> assign_new(:version, fn ->
        case Application.spec(:streamix, :vsn) do
          nil -> ""
          vsn -> to_string(vsn)
        end
      end)
      |> assign_new(:year, fn -> Date.utc_today().year end)
      |> assign_new(:admin?, fn -> admin_scope?(assigns[:current_scope]) end)

    ~H"""
    <footer class="mt-12 sm:mt-16 border-t border-border/50 bg-background">
      <div class="mx-auto max-w-7xl px-[4%] py-8 sm:py-10">
        <div class="grid gap-8 lg:grid-cols-[minmax(0,1.15fr)_minmax(0,2fr)] lg:gap-12">
          <section aria-label="Sobre o Streamix" class="max-w-sm">
            <.link
              href={~p"/"}
              class="inline-flex min-h-11 items-center gap-2 text-text-primary"
            >
              <span class="inline-flex size-8 items-center justify-center rounded-lg bg-brand text-sm font-bold text-white">
                S
              </span>
              <span class="text-base font-semibold">Streamix</span>
            </.link>
            <p class="mt-3 text-sm leading-6 text-text-muted">
              Catálogo, histórico, favoritos e salas sincronizadas em uma experiência única.
            </p>
          </section>

          <nav
            aria-label="Links do rodapé"
            class="grid grid-cols-2 gap-6 sm:grid-cols-4 sm:gap-8"
          >
            <div>
              <h3 class="mb-3 text-xs font-semibold uppercase text-text-secondary">
                Assistir
              </h3>
              <ul class="space-y-2">
                <li><.footer_link href={~p"/"}>Início</.footer_link></li>
                <li><.footer_link href={~p"/browse"}>Catálogo</.footer_link></li>
                <li><.footer_link href={~p"/favorites"}>Minha Lista</.footer_link></li>
                <li><.footer_link href={~p"/history"}>Histórico</.footer_link></li>
              </ul>
            </div>

            <div>
              <h3 class="mb-3 text-xs font-semibold uppercase text-text-secondary">
                Social
              </h3>
              <ul class="space-y-2">
                <li><.footer_link href={~p"/party"}>Watch Party</.footer_link></li>
                <li><.footer_link href={~p"/party"}>Minhas Salas</.footer_link></li>
                <li><.footer_link href={~p"/party"}>Entrar em Sala</.footer_link></li>
              </ul>
            </div>

            <div>
              <h3 class="mb-3 text-xs font-semibold uppercase text-text-secondary">
                Conta
              </h3>
              <ul class="space-y-2">
                <li><.footer_link href={~p"/settings"}>Configurações</.footer_link></li>
                <li><.footer_link href={~p"/providers"}>Provedores</.footer_link></li>
                <li :if={@admin?}><.footer_link href={~p"/admin"}>Admin</.footer_link></li>
              </ul>
            </div>

            <div>
              <h3 class="mb-3 text-xs font-semibold uppercase text-text-secondary">
                Projeto
              </h3>
              <ul class="space-y-2">
                <li>
                  <.external_footer_link href="https://github.com/gabrielmaialva33/streamix#readme">
                    Documentação
                  </.external_footer_link>
                </li>
                <li>
                  <.external_footer_link href="https://github.com/gabrielmaialva33/streamix">
                    GitHub
                  </.external_footer_link>
                </li>
              </ul>
            </div>
          </nav>
        </div>

        <div class="mt-8 flex flex-col gap-3 border-t border-border/30 pt-6 text-xs text-text-muted sm:flex-row sm:items-center sm:justify-between">
          <p class="flex flex-wrap items-center gap-x-2 gap-y-1">
            <span>© {@year} Streamix</span>
            <span :if={@version != ""} class="text-text-muted/70">v{@version}</span>
          </p>
          <p>Powered by Maia</p>
        </div>
      </div>
    </footer>
    """
  end

  attr :href, :any, required: true
  slot :inner_block, required: true

  defp footer_link(assigns) do
    ~H"""
    <.link
      href={@href}
      class="inline-flex min-h-11 min-w-11 items-center text-sm text-text-muted transition-colors hover:text-text-primary focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-brand focus-visible:ring-offset-2 focus-visible:ring-offset-background sm:min-h-0 sm:min-w-0"
    >
      {render_slot(@inner_block)}
    </.link>
    """
  end

  attr :href, :string, required: true
  slot :inner_block, required: true

  defp external_footer_link(assigns) do
    ~H"""
    <a
      href={@href}
      target="_blank"
      rel="noopener noreferrer"
      class="inline-flex min-h-11 min-w-11 items-center text-sm text-text-muted transition-colors hover:text-text-primary focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-brand focus-visible:ring-offset-2 focus-visible:ring-offset-background sm:min-h-0 sm:min-w-0"
    >
      {render_slot(@inner_block)}
    </a>
    """
  end

  defp admin_scope?(%{user: user}) when not is_nil(user), do: accounts_admin?(user)
  defp admin_scope?(_), do: false

  defp accounts_admin?(user) do
    if function_exported?(Streamix.Accounts, :admin?, 1) do
      Streamix.Accounts.admin?(user)
    else
      false
    end
  end
end
