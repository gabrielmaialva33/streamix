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

      <div id="admin-dashboard-stats" class="grid grid-cols-2 gap-3 sm:gap-4 lg:grid-cols-4">
        <.stat_card label="Total Usuários" value={"#{@stats.total_users}"} icon="hero-users" />
        <.stat_card
          label="Assinaturas ativas"
          value={"#{@stats.active_subscriptions}"}
          icon="hero-check-badge"
        />
        <.stat_card label="Planos ativos" value={"#{@stats.active_plans}"} icon="hero-credit-card" />
        <.stat_card
          label="Receita mensal"
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

        <div class="grid gap-3 sm:grid-cols-2 lg:grid-cols-5">
          <.operation_card
            label="Provedores"
            status={@operations.providers.status}
            detail={format_provider_counts(@operations.providers.counts)}
          />
          <.operation_card
            label="Torrent / rqbit"
            status={@operations.torrent.status}
            detail={"#{@operations.torrent.active_torrents} torrents ativos"}
          />
          <.operation_card
            label="Cota GIndex"
            status={quota_status(@operations.gindex.quota)}
            detail={format_quota(@operations.gindex.quota)}
          />
          <.operation_card
            label="Oban"
            status={oban_status(@operations.oban)}
            detail={format_oban(@operations.oban)}
          />
          <.operation_card
            label="QoE (24h)"
            status={qoe_status(@operations.qoe)}
            detail={format_qoe(@operations.qoe)}
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

      <section id="web-vitals-slo" class="surface-card p-5">
        <div class="mb-4">
          <h2 class="text-lg font-semibold text-text-primary">Core Web Vitals (24h)</h2>
          <p class="text-sm text-text-secondary">
            p75 real por dispositivo. Meta: LCP ≤ 2,5s · INP ≤ 200ms · CLS ≤ 0,1.
          </p>
        </div>

        <div class="grid gap-3 lg:grid-cols-3">
          <.web_vitals_card
            id="web-vitals-all"
            label="Todos"
            segment={vital_segment(@operations.qoe, :all)}
          />
          <.web_vitals_card
            id="web-vitals-mobile"
            label="Mobile / PWA"
            segment={vital_segment(@operations.qoe, :mobile)}
          />
          <.web_vitals_card
            id="web-vitals-desktop"
            label="Desktop"
            segment={vital_segment(@operations.qoe, :desktop)}
          />
        </div>
      </section>

      <div class="grid grid-cols-1 gap-4 lg:grid-cols-2 lg:gap-6">
        <section class="surface-card p-4 sm:p-5">
          <h2 class="mb-4 text-lg font-semibold text-text-primary">Últimos usuários</h2>
          <div data-admin-table="recent-users" class="overflow-x-auto">
            <table class="w-full min-w-[34rem] text-sm">
              <thead>
                <tr class="border-b border-border text-left text-text-muted">
                  <th class="pb-2">Email</th>
                  <th class="pb-2">Perfil</th>
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
          </div>
        </section>

        <section class="surface-card p-4 sm:p-5">
          <h2 class="mb-4 text-lg font-semibold text-text-primary">Últimas assinaturas</h2>
          <div data-admin-table="recent-subscriptions" class="overflow-x-auto">
            <table class="w-full min-w-[34rem] text-sm">
              <thead>
                <tr class="border-b border-border text-left text-text-muted">
                  <th class="pb-2">Usuário</th>
                  <th class="pb-2">Plano</th>
                  <th class="pb-2">Status</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={sub <- @recent_subs} class="border-b border-border/50">
                  <td class="py-2 text-text-primary">{sub.user_email}</td>
                  <td class="py-2 text-text-secondary">{sub.plan.name}</td>
                  <td class="py-2"><.status_badge status={sub.status} /></td>
                </tr>
                <tr :if={@recent_subs == []}>
                  <td colspan="3" class="py-4 text-center text-text-muted">
                    Nenhuma assinatura
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
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

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :segment, :map, required: true

  defp web_vitals_card(assigns) do
    ~H"""
    <article id={@id} class="rounded-lg border border-border bg-surface-hover/50 p-4">
      <div class="flex items-center justify-between gap-2">
        <h3 class="text-sm font-semibold text-text-primary">{@label}</h3>
        <span class={[
          "size-2.5 rounded-full",
          status_color(vital_operation_status(@segment.status))
        ]} />
      </div>
      <p class="mt-1 text-xs text-text-muted">{@segment.sample_count} navegações</p>
      <dl class="mt-3 grid grid-cols-3 gap-2 text-xs">
        <div>
          <dt class="text-text-muted">LCP</dt>
          <dd class="font-medium text-text-primary">{format_vital(@segment.lcp, :milliseconds)}</dd>
        </div>
        <div>
          <dt class="text-text-muted">INP</dt>
          <dd class="font-medium text-text-primary">{format_vital(@segment.inp, :milliseconds)}</dd>
        </div>
        <div>
          <dt class="text-text-muted">CLS</dt>
          <dd class="font-medium text-text-primary">{format_vital(@segment.cls, :cls)}</dd>
        </div>
      </dl>
    </article>
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

  defp qoe_status(qoe) do
    if Map.get(qoe, :error_count, 0) > 0, do: :degraded, else: :healthy
  end

  defp format_qoe(qoe) do
    "#{Map.get(qoe, :playback_sessions, 0)} sessões · TTFF #{Map.get(qoe, :avg_ttff_ms, 0)}ms"
  end

  defp vital_segment(qoe, segment) do
    qoe
    |> Map.get(:web_vitals_slo, %{})
    |> Map.get(segment, empty_vital_segment())
  end

  defp empty_vital_segment do
    empty_metric = %{p75: nil, samples: 0, status: :insufficient_data}

    %{
      sample_count: 0,
      status: :insufficient_data,
      lcp: empty_metric,
      inp: empty_metric,
      cls: empty_metric
    }
  end

  defp vital_operation_status(:good), do: :healthy
  defp vital_operation_status(:needs_improvement), do: :degraded
  defp vital_operation_status(:poor), do: :unhealthy
  defp vital_operation_status(_status), do: :disabled

  defp format_vital(%{p75: nil}, _unit), do: "sem dados"
  defp format_vital(%{p75: value}, :milliseconds), do: "#{value}ms"

  defp format_vital(%{p75: value}, :cls) do
    value
    |> Kernel./(1_000)
    |> :erlang.float_to_binary(decimals: 3)
  end

  defp sum_counts(counts), do: counts |> Map.values() |> Enum.sum()
  defp event_count(counts, key), do: Map.get(counts, key, 0)
end
