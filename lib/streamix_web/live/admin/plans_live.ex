defmodule StreamixWeb.Admin.PlansLive do
  use StreamixWeb, :live_view

  import StreamixWeb.AdminComponents

  alias Streamix.Billing

  def mount(_params, _session, socket) do
    plans = Billing.list_plans()

    socket =
      socket
      |> assign(page_title: "Admin — Planos", current_path: "/admin/plans")
      |> assign(plans: plans)

    {:ok, socket}
  end

  def render(assigns) do
    ~H"""
    <div id="admin-plans" class="space-y-6">
      <.admin_tabs current_path={@current_path} />

      <div class="flex items-center justify-between">
        <h1 class="text-xl font-semibold text-text-primary">Planos</h1>
        <.link
          navigate={~p"/admin/plans/new"}
          class="inline-flex items-center gap-2 rounded-lg bg-brand px-4 py-2.5 text-sm font-semibold text-white hover:bg-brand-hover transition-colors focus:outline-none focus:ring-2 focus:ring-brand focus:ring-offset-2 focus:ring-offset-background"
        >
          <.icon name="hero-plus" class="size-4" /> Novo plano
        </.link>
      </div>

      <div
        :if={@plans != []}
        class="rounded-lg border border-border bg-surface overflow-hidden shadow-card"
      >
        <table class="w-full text-sm">
          <thead>
            <tr class="text-left text-text-muted border-b border-border bg-surface-hover/50">
              <th class="px-4 py-3">Nome</th>
              <th class="px-4 py-3">Slug</th>
              <th class="px-4 py-3">Preço</th>
              <th class="px-4 py-3">Intervalo</th>
              <th class="px-4 py-3">Features</th>
              <th class="px-4 py-3">Global</th>
              <th class="px-4 py-3">Status</th>
              <th class="px-4 py-3"></th>
            </tr>
          </thead>
          <tbody>
            <tr :for={plan <- @plans} class="border-b border-border/50 hover:bg-surface-hover/30">
              <td class="px-4 py-3 font-medium text-text-primary">{plan.name}</td>
              <td class="px-4 py-3 text-text-secondary font-mono text-xs">{plan.slug}</td>
              <td class="px-4 py-3 text-text-primary">
                {format_price(plan.price_cents, plan.currency)}
              </td>
              <td class="px-4 py-3 text-text-secondary">{plan.billing_interval}</td>
              <td class="px-4 py-3 text-text-secondary">
                <div class="flex flex-wrap gap-1.5">
                  <span
                    :for={feature <- visible_features(plan)}
                    class="rounded-md border border-border bg-surface-hover px-2 py-1 text-xs"
                  >
                    {feature}
                  </span>
                </div>
              </td>
              <td class="px-4 py-3">
                <.icon
                  name={if plan.grants_global_access, do: "hero-check-circle", else: "hero-x-circle"}
                  class={[
                    "size-5",
                    plan.grants_global_access && "text-success",
                    !plan.grants_global_access && "text-text-muted"
                  ]}
                />
              </td>
              <td class="px-4 py-3">
                <.status_badge status={if plan.active, do: "active", else: "expired"} />
              </td>
              <td class="px-4 py-3">
                <.link
                  navigate={~p"/admin/plans/#{plan.id}"}
                  class="text-brand hover:underline text-sm"
                >
                  Editar
                </.link>
              </td>
            </tr>
          </tbody>
        </table>
      </div>

      <div
        :if={@plans == []}
        class="rounded-lg border border-dashed border-border bg-surface/50 p-8 text-center"
      >
        <.icon name="hero-credit-card" class="mx-auto mb-3 size-10 text-text-muted" />
        <h3 class="text-lg font-semibold text-text-primary">Nenhum plano cadastrado</h3>
        <p class="mt-2 text-sm text-text-secondary">Crie o primeiro plano para começar.</p>
      </div>
    </div>
    """
  end

  defp format_price(cents, currency) when is_integer(cents) do
    symbol =
      case currency do
        "BRL" -> "R$"
        "USD" -> "$"
        "EUR" -> "€"
        other -> other
      end

    amount = :erlang.float_to_binary(cents / 100, decimals: 2) |> String.replace(".", ",")
    "#{symbol} #{amount}"
  end

  defp format_price(_, _), do: "-"

  defp visible_features(plan) do
    plan.features
    |> Enum.filter(& &1.enabled)
    |> Enum.map(fn
      %{feature: feature, limit: limit} when is_integer(limit) -> "#{feature}: #{limit}"
      %{feature: feature} -> feature
    end)
  end
end
