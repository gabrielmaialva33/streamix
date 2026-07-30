defmodule StreamixWeb.Admin.BillingLive do
  use StreamixWeb, :live_view

  import StreamixWeb.AdminComponents

  alias Streamix.Billing

  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(page_title: "Admin — Cobrança", current_path: "/admin/billing")
      |> load_billing()

    {:ok, socket}
  end

  def handle_event("reconcile_stripe", _params, socket) do
    case Billing.reconcile_stripe_subscriptions() do
      {:ok, _summary} ->
        {:noreply,
         socket
         |> put_flash(:info, "Reconciliação Stripe concluída")
         |> load_billing()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Falha ao reconciliar Stripe: #{inspect(reason)}")}
    end
  end

  def render(assigns) do
    ~H"""
    <div id="admin-billing" class="space-y-6">
      <.admin_tabs current_path={@current_path} />

      <div class="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
        <h1 class="text-xl font-semibold text-text-primary">Cobrança</h1>
        <button
          type="button"
          phx-click="reconcile_stripe"
          class="inline-flex min-h-11 items-center justify-center gap-2 rounded-lg bg-brand px-4 py-2.5 text-sm font-semibold text-white hover:bg-brand-hover"
        >
          <.icon name="hero-arrow-path" class="size-4" /> Reconciliar Stripe
        </button>
      </div>

      <div class="grid grid-cols-2 gap-3 sm:gap-4 md:grid-cols-4">
        <.stat_card
          label="MRR"
          value={format_price(@stats.monthly_revenue_cents, "BRL")}
          icon="hero-banknotes"
        />
        <.stat_card
          label="Assinaturas"
          value={to_string(@stats.active_subscriptions)}
          icon="hero-check-circle"
        />
        <.stat_card label="Clientes" value={to_string(@stats.billing_customers)} icon="hero-users" />
        <.stat_card
          label="Falhas"
          value={to_string(@stats.failed_payments)}
          icon="hero-exclamation-triangle"
        />
      </div>

      <section class="surface-card">
        <div class="border-b border-border px-5 py-4">
          <h2 class="font-semibold text-text-primary">Pagamentos recentes</h2>
        </div>
        <div data-admin-table="payments" class="overflow-x-auto">
          <table class="w-full min-w-[36rem] text-sm">
            <thead class="bg-surface-hover/50 text-left text-text-muted">
              <tr>
                <th class="px-5 py-3">Usuário</th>
                <th class="px-5 py-3">Plano</th>
                <th class="px-5 py-3">Status</th>
                <th class="px-5 py-3">Valor</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={payment <- @payments} class="border-t border-border/50">
                <td class="px-5 py-3 text-text-primary">{payment.user.email}</td>
                <td class="px-5 py-3 text-text-secondary">{payment.plan.name}</td>
                <td class="px-5 py-3"><.status_badge status={payment.status} /></td>
                <td class="px-5 py-3 text-text-primary">
                  {format_price(payment.amount_cents, payment.currency)}
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </section>

      <section class="surface-card">
        <div class="border-b border-border px-5 py-4">
          <h2 class="font-semibold text-text-primary">Faturas recentes</h2>
        </div>
        <div data-admin-table="invoices" class="overflow-x-auto">
          <table class="w-full min-w-[36rem] text-sm">
            <thead class="bg-surface-hover/50 text-left text-text-muted">
              <tr>
                <th class="px-5 py-3">Usuário</th>
                <th class="px-5 py-3">Número</th>
                <th class="px-5 py-3">Status</th>
                <th class="px-5 py-3">Valor pago</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={invoice <- @invoices} class="border-t border-border/50">
                <td class="px-5 py-3 text-text-primary">{invoice.user.email}</td>
                <td class="px-5 py-3 text-text-secondary">
                  {invoice.number || invoice.external_id || "-"}
                </td>
                <td class="px-5 py-3"><.status_badge status={invoice.status} /></td>
                <td class="px-5 py-3 text-text-primary">
                  {format_price(invoice.amount_paid_cents, invoice.currency)}
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </section>
    </div>
    """
  end

  defp load_billing(socket) do
    socket
    |> assign(stats: Billing.admin_stats())
    |> assign(payments: Billing.list_recent_payments())
    |> assign(invoices: Billing.list_recent_invoices())
  end

  defp format_price(cents, currency) when is_integer(cents) do
    "#{currency} " <>
      (:erlang.float_to_binary(cents / 100, decimals: 2) |> String.replace(".", ","))
  end

  defp format_price(_, currency), do: currency || "-"
end
