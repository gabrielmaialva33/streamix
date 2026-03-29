defmodule StreamixWeb.PlansLive do
  use StreamixWeb, :live_view

  alias Streamix.Billing

  def mount(_params, _session, socket) do
    plans = Billing.list_active_plans()

    active_subscription =
      case socket.assigns.current_scope do
        nil -> nil
        scope -> Billing.active_subscription_for_user(scope.user)
      end

    current_plan_id = active_subscription && active_subscription.plan_id

    socket =
      socket
      |> assign(page_title: "Planos")
      |> assign(current_path: "/plans")
      |> assign(plans: plans)
      |> assign(active_subscription: active_subscription)
      |> assign(current_plan_id: current_plan_id)
      |> assign(subscription_state: subscription_state(active_subscription))

    {:ok, socket}
  end

  def render(assigns) do
    ~H"""
    <div id="plans-page" class="space-y-8 pb-12">
      <section class="rounded-3xl border border-border bg-gradient-to-br from-surface via-background to-brand/10 p-6 sm:p-8">
        <div class="max-w-3xl space-y-4">
          <.premium_badge />
          <h1 class="text-3xl sm:text-5xl font-bold text-text-primary tracking-tight">
            Acesso premium para todo o catálogo
          </h1>
          <p class="text-base sm:text-lg text-text-secondary max-w-2xl">
            Escolha um plano ativo para liberar o acesso global, acompanhar a assinatura atual e evoluir sem sair da experiência Streamix.
          </p>
        </div>
      </section>

      <section :if={@current_scope} id="current-subscription" data-status={@subscription_state}>
        <div class="rounded-2xl border border-border bg-surface p-5 sm:p-6">
          <div class="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
            <div class="space-y-1.5">
              <p class="text-sm font-semibold uppercase tracking-[0.18em] text-text-muted">
                Assinatura atual
              </p>
              <h2 class="text-xl font-semibold text-text-primary">
                <%= if @active_subscription do %>
                  {@active_subscription.plan.name}
                <% else %>
                  Nenhuma assinatura ativa
                <% end %>
              </h2>
              <p class="text-sm text-text-secondary">
                <%= if @active_subscription do %>
                  Seu plano está ativo e libera o acesso global ao catálogo.
                <% else %>
                  Você ainda pode explorar os planos disponíveis e ativar o acesso premium.
                <% end %>
              </p>
            </div>

            <div
              :if={@active_subscription}
              class="rounded-xl border border-brand/20 bg-brand/10 px-4 py-3"
            >
              <p class="text-xs font-semibold uppercase tracking-[0.18em] text-brand">
                Estado
              </p>
              <p class="text-sm font-medium text-text-primary">
                {@active_subscription.status |> String.capitalize()}
              </p>
            </div>
          </div>
        </div>
      </section>

      <section>
        <div class="flex items-end justify-between gap-4 mb-4">
          <div>
            <h2 class="text-xl sm:text-2xl font-semibold text-text-primary">Planos ativos</h2>
            <p class="text-sm text-text-secondary">
              Compare os planos publicados e escolha o nível que faz sentido para a sua conta.
            </p>
          </div>
          <.premium_badge label="Ativos" class="hidden sm:inline-flex" />
        </div>

        <div id="plans-list" class="grid gap-4 lg:grid-cols-2">
          <article
            :for={plan <- @plans}
            id={"plan-card-#{plan.slug}"}
            data-active={plan.id == @current_plan_id}
            class={[
              "flex h-full flex-col rounded-2xl border p-5 sm:p-6 transition-all",
              plan.id == @current_plan_id &&
                "border-brand/40 bg-brand/10 shadow-lg shadow-brand/10",
              plan.id != @current_plan_id &&
                "border-border bg-surface hover:border-brand/20 hover:-translate-y-0.5"
            ]}
          >
            <div class="flex items-start justify-between gap-3">
              <div class="space-y-1">
                <h3 class="text-lg sm:text-xl font-semibold text-text-primary">{plan.name}</h3>
                <p class="text-sm text-text-secondary">{plan.description}</p>
              </div>
              <.plan_access_badge
                id={"plan-badge-#{plan.slug}"}
                grants_global_access={plan.grants_global_access}
              />
            </div>

            <div class="mt-6 flex items-end gap-2">
              <span class="text-3xl font-bold text-text-primary">
                {format_price(plan.price_cents, plan.currency)}
              </span>
              <span class="pb-1 text-sm text-text-secondary">
                /{interval_label(plan.billing_interval)}
              </span>
            </div>

            <div class="mt-5 flex items-center gap-2 text-sm text-text-secondary">
              <.icon
                name={if plan.grants_global_access, do: "hero-check-circle", else: "hero-clock"}
                class={["size-4", plan.grants_global_access && "text-brand"]}
              />
              <span>
                <%= if plan.grants_global_access do %>
                  Atualizações contínuas e acesso premium
                <% else %>
                  Ativação manual antes da liberação
                <% end %>
              </span>
            </div>

            <div class="mt-4 flex items-center gap-2 text-sm text-text-secondary">
              <.icon
                name={
                  if plan.grants_global_access,
                    do: "hero-check-circle",
                    else: "hero-information-circle"
                }
                class={["size-4", plan.grants_global_access && "text-brand"]}
              />
              <span>
                <%= if plan.grants_global_access do %>
                  Libera o catálogo global em toda a plataforma
                <% else %>
                  Disponível sob ativação manual
                <% end %>
              </span>
            </div>

            <div class="mt-6 pt-4 border-t border-border flex items-center justify-between gap-3">
              <p class="text-xs uppercase tracking-[0.18em] text-text-muted">
                {if plan.grants_global_access, do: "Premium", else: "Plano"}
              </p>
              <%= if plan.id == @current_plan_id do %>
                <span
                  id={"plan-cta-#{plan.slug}"}
                  data-cta-state="current"
                  class="inline-flex items-center gap-2 rounded-xl bg-brand px-4 py-2.5 text-sm font-semibold text-white"
                >
                  <.icon name="hero-check" class="size-4" /> Plano atual
                </span>
              <% else %>
                <%= if @current_scope do %>
                  <span
                    id={"plan-cta-#{plan.slug}"}
                    data-cta-state="manual"
                    class="inline-flex items-center gap-2 rounded-xl bg-surface-hover px-4 py-2.5 text-sm font-semibold text-text-primary"
                  >
                    <.icon name="hero-clock" class="size-4" /> Disponível sob ativação
                  </span>
                <% else %>
                  <.link
                    id={"plan-cta-#{plan.slug}"}
                    navigate={~p"/register"}
                    data-cta-state="register"
                    class="inline-flex items-center gap-2 rounded-xl bg-brand px-4 py-2.5 text-sm font-semibold text-white transition-colors hover:bg-brand-hover"
                  >
                    <.icon name="hero-user-plus" class="size-4" /> Criar conta
                  </.link>
                <% end %>
              <% end %>
            </div>
          </article>
        </div>

        <div
          :if={@plans == []}
          class="rounded-2xl border border-dashed border-border bg-surface/50 p-8 text-center"
        >
          <.icon name="hero-sparkles" class="mx-auto mb-3 size-10 text-text-muted" />
          <h3 class="text-lg font-semibold text-text-primary">Nenhum plano ativo no momento</h3>
          <p class="mt-2 text-sm text-text-secondary">
            Cadastre planos ativos no billing para exibir as opções premium nesta página.
          </p>
        </div>
      </section>
    </div>
    """
  end

  defp subscription_state(nil), do: "none"
  defp subscription_state(_subscription), do: "active"

  defp format_price(price_cents, currency) when is_integer(price_cents) do
    value = price_cents / 100

    locale_currency =
      case currency do
        "BRL" -> "R$"
        "EUR" -> "€"
        "USD" -> "$"
        _ -> currency
      end

    amount =
      value
      |> :erlang.float_to_binary(decimals: 2)
      |> String.replace(".", ",")

    "#{locale_currency} #{amount}"
  end

  defp format_price(_, currency), do: currency

  defp interval_label("day"), do: "dia"
  defp interval_label("week"), do: "semana"
  defp interval_label("month"), do: "mês"
  defp interval_label("year"), do: "ano"
  defp interval_label(other), do: other
end
