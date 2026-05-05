defmodule StreamixWeb.BillingLive do
  use StreamixWeb, :live_view

  alias Streamix.Billing
  alias Streamix.Billing.Stripe

  def mount(_params, _session, socket) do
    user = socket.assigns.current_scope.user
    active_subscription = Billing.active_subscription_for_user(user)

    socket =
      socket
      |> assign(page_title: "Billing")
      |> assign(current_path: "/billing")
      |> assign(active_subscription: active_subscription)
      |> assign(invoices: Billing.list_invoices(user))
      |> assign(payments: Billing.list_payments(user))
      |> assign(active_playback_count: Billing.active_playback_count(user))
      |> assign(stripe_customer: Billing.get_billing_customer(user, :stripe))

    {:ok, socket}
  end

  def handle_event("stripe_portal", _params, socket) do
    user = socket.assigns.current_scope.user

    case Stripe.create_portal_session(user, StreamixWeb.Endpoint.url() <> ~p"/billing") do
      {:ok, url} ->
        {:noreply, Phoenix.LiveView.redirect(socket, external: url)}

      {:error, :stripe_customer_not_found} ->
        {:noreply,
         put_flash(socket, :error, "Você ainda não tem uma assinatura Stripe vinculada.")}

      {:error, :stripe_not_configured} ->
        {:noreply,
         put_flash(socket, :error, "Portal Stripe ainda não está configurado no servidor.")}

      {:error, reason} ->
        {:noreply,
         put_flash(socket, :error, "Não foi possível abrir o portal: #{inspect(reason)}")}
    end
  end

  def render(assigns) do
    ~H"""
    <div id="billing-page" class="space-y-6 pb-12">
      <div class="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
        <div>
          <h1 class="text-2xl sm:text-3xl font-bold text-text-primary">Billing</h1>
          <p class="mt-1 text-sm text-text-secondary">
            Plano atual, uso, invoices e pagamentos da sua conta.
          </p>
        </div>

        <button
          type="button"
          phx-click="stripe_portal"
          class="inline-flex items-center justify-center gap-2 rounded-lg bg-brand px-4 py-2.5 text-sm font-semibold text-white hover:bg-brand-hover"
        >
          <.icon name="hero-arrow-top-right-on-square" class="size-4" /> Portal Stripe
        </button>
      </div>

      <section class="grid gap-4 lg:grid-cols-3">
        <div class="rounded-lg border border-border bg-surface p-5">
          <p class="text-xs font-semibold uppercase tracking-[0.18em] text-text-muted">Plano</p>
          <h2 class="mt-2 text-xl font-semibold text-text-primary">
            <%= if @active_subscription do %>
              {@active_subscription.plan.name}
            <% else %>
              Sem plano ativo
            <% end %>
          </h2>
          <p class="mt-2 text-sm text-text-secondary">
            <%= if @active_subscription do %>
              Status {@active_subscription.status}
            <% else %>
              Assine um plano para liberar catálogo global e recursos premium.
            <% end %>
          </p>
        </div>

        <div class="rounded-lg border border-border bg-surface p-5">
          <p class="text-xs font-semibold uppercase tracking-[0.18em] text-text-muted">Telas</p>
          <h2 class="mt-2 text-xl font-semibold text-text-primary">
            {@active_playback_count} / {feature_limit(@active_subscription, "concurrent_streams")}
          </h2>
          <p class="mt-2 text-sm text-text-secondary">Sessões ativas agora.</p>
        </div>

        <div class="rounded-lg border border-border bg-surface p-5">
          <p class="text-xs font-semibold uppercase tracking-[0.18em] text-text-muted">Stripe</p>
          <h2 class="mt-2 text-xl font-semibold text-text-primary">
            <%= if @stripe_customer do %>
              Vinculado
            <% else %>
              Não vinculado
            <% end %>
          </h2>
          <p class="mt-2 text-sm text-text-secondary">
            Webhooks vinculam automaticamente o customer após o primeiro checkout pago.
          </p>
        </div>
      </section>

      <section class="rounded-lg border border-border bg-surface overflow-hidden">
        <div class="border-b border-border px-5 py-4">
          <h2 class="font-semibold text-text-primary">Invoices</h2>
        </div>
        <table class="w-full text-sm">
          <thead class="bg-surface-hover/50 text-left text-text-muted">
            <tr>
              <th class="px-5 py-3">Número</th>
              <th class="px-5 py-3">Status</th>
              <th class="px-5 py-3">Valor</th>
              <th class="px-5 py-3">Pago em</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={invoice <- @invoices} class="border-t border-border/50">
              <td class="px-5 py-3 text-text-primary">
                {invoice.number || invoice.external_id || "-"}
              </td>
              <td class="px-5 py-3 text-text-secondary">{invoice.status}</td>
              <td class="px-5 py-3 text-text-primary">
                {format_price(invoice.amount_paid_cents, invoice.currency)}
              </td>
              <td class="px-5 py-3 text-text-secondary">{format_datetime(invoice.paid_at)}</td>
            </tr>
          </tbody>
        </table>
        <p :if={@invoices == []} class="px-5 py-6 text-sm text-text-secondary">
          Nenhuma invoice registrada ainda.
        </p>
      </section>

      <section class="rounded-lg border border-border bg-surface overflow-hidden">
        <div class="border-b border-border px-5 py-4">
          <h2 class="font-semibold text-text-primary">Pagamentos</h2>
        </div>
        <table class="w-full text-sm">
          <thead class="bg-surface-hover/50 text-left text-text-muted">
            <tr>
              <th class="px-5 py-3">Provider</th>
              <th class="px-5 py-3">Status</th>
              <th class="px-5 py-3">Valor</th>
              <th class="px-5 py-3">Pago em</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={payment <- @payments} class="border-t border-border/50">
              <td class="px-5 py-3 text-text-primary">{payment.provider}</td>
              <td class="px-5 py-3 text-text-secondary">{payment.status}</td>
              <td class="px-5 py-3 text-text-primary">
                {format_price(payment.amount_cents, payment.currency)}
              </td>
              <td class="px-5 py-3 text-text-secondary">{format_datetime(payment.paid_at)}</td>
            </tr>
          </tbody>
        </table>
        <p :if={@payments == []} class="px-5 py-6 text-sm text-text-secondary">
          Nenhum pagamento registrado ainda.
        </p>
      </section>
    </div>
    """
  end

  defp feature_limit(nil, _feature), do: "-"

  defp feature_limit(subscription, feature) do
    subscription.plan.features
    |> Enum.find(&(&1.feature == feature and &1.enabled))
    |> case do
      %{limit: limit} when is_integer(limit) -> limit
      _ -> "sem limite"
    end
  end

  defp format_price(cents, currency) when is_integer(cents) do
    "#{currency} " <>
      (:erlang.float_to_binary(cents / 100, decimals: 2) |> String.replace(".", ","))
  end

  defp format_price(_, currency), do: currency || "-"

  defp format_datetime(nil), do: "-"
  defp format_datetime(%DateTime{} = datetime), do: Calendar.strftime(datetime, "%d/%m/%Y %H:%M")
end
