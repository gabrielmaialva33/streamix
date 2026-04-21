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
      |> assign_new(:admin?, fn ->
        case assigns[:current_scope] do
          %{user: user} when not is_nil(user) ->
            if function_exported?(Streamix.Accounts, :admin?, 1) do
              Streamix.Accounts.admin?(user)
            else
              false
            end

          _ ->
            false
        end
      end)

    ~H"""
    <footer class="mt-12 sm:mt-16 border-t border-border/50 bg-background">
      <div class="px-[4%] py-8 sm:py-10 max-w-7xl mx-auto">
        <div class="grid grid-cols-2 sm:grid-cols-4 gap-6 sm:gap-8">
          <div>
            <h3 class="text-xs font-semibold uppercase tracking-wider text-text-secondary mb-3">
              Navegar
            </h3>
            <ul class="space-y-2">
              <li>
                <.link
                  navigate={~p"/"}
                  class="text-sm text-text-muted hover:text-text-primary transition-colors"
                >
                  Início
                </.link>
              </li>
              <li>
                <.link
                  navigate={~p"/browse"}
                  class="text-sm text-text-muted hover:text-text-primary transition-colors"
                >
                  Catálogo
                </.link>
              </li>
              <li>
                <.link
                  navigate={~p"/favorites"}
                  class="text-sm text-text-muted hover:text-text-primary transition-colors"
                >
                  Minha Lista
                </.link>
              </li>
              <li>
                <.link
                  navigate={~p"/history"}
                  class="text-sm text-text-muted hover:text-text-primary transition-colors"
                >
                  Histórico
                </.link>
              </li>
            </ul>
          </div>

          <div>
            <h3 class="text-xs font-semibold uppercase tracking-wider text-text-secondary mb-3">
              Watch Party
            </h3>
            <ul class="space-y-2">
              <li>
                <.link
                  navigate={~p"/party"}
                  class="text-sm text-text-muted hover:text-text-primary transition-colors"
                >
                  Minhas Salas
                </.link>
              </li>
              <li>
                <.link
                  navigate={~p"/party"}
                  class="text-sm text-text-muted hover:text-text-primary transition-colors"
                >
                  Criar Sala
                </.link>
              </li>
            </ul>
          </div>

          <div>
            <h3 class="text-xs font-semibold uppercase tracking-wider text-text-secondary mb-3">
              Recursos
            </h3>
            <ul class="space-y-2">
              <li>
                <a
                  href="#"
                  class="text-sm text-text-muted hover:text-text-primary transition-colors"
                >
                  Documentação
                </a>
              </li>
              <li>
                <a
                  href="#"
                  class="text-sm text-text-muted hover:text-text-primary transition-colors"
                >
                  GitHub
                </a>
              </li>
              <li>
                <a
                  href="#"
                  class="text-sm text-text-muted hover:text-text-primary transition-colors"
                >
                  Status
                </a>
              </li>
            </ul>
          </div>

          <div>
            <h3 class="text-xs font-semibold uppercase tracking-wider text-text-secondary mb-3">
              Conta
            </h3>
            <ul class="space-y-2">
              <li>
                <.link
                  navigate={~p"/settings"}
                  class="text-sm text-text-muted hover:text-text-primary transition-colors"
                >
                  Configurações
                </.link>
              </li>
              <li>
                <.link
                  navigate={~p"/providers"}
                  class="text-sm text-text-muted hover:text-text-primary transition-colors"
                >
                  Provedores
                </.link>
              </li>
              <li :if={@admin?}>
                <.link
                  navigate={~p"/admin"}
                  class="text-sm text-text-muted hover:text-text-primary transition-colors"
                >
                  Admin
                </.link>
              </li>
            </ul>
          </div>
        </div>

        <div class="mt-8 pt-6 border-t border-border/30 flex flex-col sm:flex-row items-center justify-between gap-2 text-xs text-text-muted">
          <p>
            © {@year} Streamix<span :if={@version != ""}>· v{@version}</span>
          </p>
          <p class="flex items-center gap-3">
            <span>Powered by TMDB · AniList · TomatoAnimes</span>
          </p>
        </div>
      </div>
    </footer>
    """
  end
end
