defmodule StreamixWeb.Admin.DashboardLive do
  use StreamixWeb, :live_view

  import StreamixWeb.AdminComponents

  alias Streamix.{Accounts, Billing, Operations}

  def mount(_params, _session, socket) do
    stats = Billing.admin_stats()
    recent_users = Accounts.list_users(page: 1, per_page: 10)
    recent_subs = Billing.list_subscriptions([]) |> Enum.take(10)
    operations = Operations.initial_summary()

    socket =
      socket
      |> assign(page_title: "Admin — Dashboard", current_path: "/admin")
      |> assign(stats: stats)
      |> assign(recent_users: recent_users)
      |> assign(recent_subs: recent_subs)
      |> assign(operations: operations)

    socket =
      if connected?(socket) do
        start_async(socket, :operations, &Operations.runtime_summary/0)
      else
        socket
      end

    {:ok, socket}
  end

  def handle_async(:operations, {:ok, runtime}, socket) do
    {:noreply, assign(socket, operations: Map.merge(socket.assigns.operations, runtime))}
  end

  def handle_async(:operations, {:exit, _reason}, socket), do: {:noreply, socket}

  def render(assigns) do
    ~H"""
    <div id="admin-dashboard" class="space-y-6">
      <.admin_tabs current_path={@current_path} />

      <div class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-4">
        <.stat_card label="Total Usuários" value={"#{@stats.total_users}"} icon="hero-users" />
        <.stat_card
          label="Subscriptions Ativas"
          value={"#{@stats.active_subscriptions}"}
          icon="hero-check-badge"
        />
        <.stat_card label="Planos Ativos" value={"#{@stats.active_plans}"} icon="hero-credit-card" />
        <.stat_card
          label="Receita Mensal"
          value={format_revenue(@stats.monthly_revenue_cents)}
          icon="hero-currency-dollar"
        />
      </div>

      <section id="operations-health" class="surface-card p-5">
        <div class="mb-4 flex flex-wrap items-center justify-between gap-2">
          <div>
            <h2 class="text-lg font-semibold text-text-primary">Operação</h2>
            <p class="text-sm text-text-secondary">Saúde dos serviços e revisão em produção.</p>
          </div>
          <code class="rounded bg-surface-hover px-2 py-1 text-xs text-text-secondary">
            {@operations.revision}
          </code>
        </div>

        <div class="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
          <.operation_card
            label="Providers"
            status={@operations.providers.status}
            detail={format_provider_counts(@operations.providers.counts)}
          />
          <.operation_card
            label="Torrent / rqbit"
            status={@operations.torrent.status}
            detail={"#{@operations.torrent.active_torrents} torrents ativos"}
          />
          <.operation_card
            label="GIndex quota"
            status={quota_status(@operations.gindex.quota)}
            detail={format_quota(@operations.gindex.quota)}
          />
          <.operation_card
            label="Oban"
            status={oban_status(@operations.oban)}
            detail={format_oban(@operations.oban)}
          />
        </div>

        <div class="mt-4 grid gap-3 text-xs text-text-secondary sm:grid-cols-2">
          <p>
            Falhas de playback:
            <span class="font-medium text-text-primary">
              {sum_counts(@operations.events.playback_failures)}
            </span>
          </p>
          <p>
            Estados torrent degradados/falhos:
            <span class="font-medium text-text-primary">
              {event_count(@operations.events.torrent_states, "degraded") +
                event_count(@operations.events.torrent_states, "failed")}
            </span>
          </p>
        </div>
      </section>

      <div class="grid grid-cols-1 lg:grid-cols-2 gap-6">
        <section class="surface-card p-5">
          <h2 class="text-lg font-semibold text-text-primary mb-4">Últimos Usuários</h2>
          <table class="w-full text-sm">
            <thead>
              <tr class="text-left text-text-muted border-b border-border">
                <th class="pb-2">Email</th>
                <th class="pb-2">Role</th>
                <th class="pb-2">Registrado</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={user <- @recent_users} class="border-b border-border/50">
                <td class="py-2 text-text-primary">{user.email}</td>
                <td class="py-2"><.status_badge status={user.role.name} /></td>
                <td class="py-2 text-text-secondary">
                  {Calendar.strftime(user.inserted_at, "%d/%m/%Y")}
                </td>
              </tr>
            </tbody>
          </table>
        </section>

        <section class="surface-card p-5">
          <h2 class="text-lg font-semibold text-text-primary mb-4">Últimas Subscriptions</h2>
          <table class="w-full text-sm">
            <thead>
              <tr class="text-left text-text-muted border-b border-border">
                <th class="pb-2">Usuário</th>
                <th class="pb-2">Plano</th>
                <th class="pb-2">Status</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={sub <- @recent_subs} class="border-b border-border/50">
                <td class="py-2 text-text-primary">{sub.user.email}</td>
                <td class="py-2 text-text-secondary">{sub.plan.name}</td>
                <td class="py-2"><.status_badge status={sub.status} /></td>
              </tr>
              <tr :if={@recent_subs == []}>
                <td colspan="3" class="py-4 text-center text-text-muted">Nenhuma subscription</td>
              </tr>
            </tbody>
          </table>
        </section>
      </div>
    </div>
    """
  end

  defp format_revenue(cents) when is_integer(cents) do
    value = cents / 100
    amount = :erlang.float_to_binary(value, decimals: 2) |> String.replace(".", ",")
    "R$ #{amount}"
  end

  defp format_revenue(_), do: "R$ 0,00"

  attr :label, :string, required: true
  attr :status, :atom, required: true
  attr :detail, :string, required: true

  defp operation_card(assigns) do
    ~H"""
    <div class="rounded-lg border border-border bg-surface-hover/50 p-3">
      <div class="flex items-center justify-between gap-2">
        <p class="text-sm font-medium text-text-primary">{@label}</p>
        <span class={["size-2.5 rounded-full", status_color(@status)]} />
      </div>
      <p class="mt-1 text-xs text-text-secondary">{@detail}</p>
    </div>
    """
  end

  defp status_color(:healthy), do: "bg-success"
  defp status_color(:degraded), do: "bg-warning"
  defp status_color(:unhealthy), do: "bg-error"
  defp status_color(:disabled), do: "bg-text-muted"
  defp status_color(_), do: "bg-text-muted"

  defp format_provider_counts(counts) do
    "#{Map.get(counts, :healthy, 0)} ok · #{Map.get(counts, :unhealthy, 0)} fora"
  end

  defp format_quota(quota) do
    "#{Map.get(quota, :count, 0)}/#{Map.get(quota, :limit, 0)} (#{Map.get(quota, :percent, 0)}%)"
  end

  defp quota_status(quota) do
    case Map.get(quota, :percent, 0) do
      percent when percent >= 100 -> :unhealthy
      percent when percent >= 80 -> :degraded
      _ -> :healthy
    end
  end

  defp oban_status(oban) do
    if Map.get(oban, "discarded", 0) > 0, do: :degraded, else: :healthy
  end

  defp format_oban(oban) do
    "#{Map.get(oban, "available", 0)} aguardando · #{Map.get(oban, "executing", 0)} rodando"
  end

  defp sum_counts(counts), do: counts |> Map.values() |> Enum.sum()
  defp event_count(counts, key), do: Map.get(counts, key, 0)
end
