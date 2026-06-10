defmodule StreamixWeb.Admin.PlanFormLive do
  use StreamixWeb, :live_view

  import StreamixWeb.AdminComponents

  alias Streamix.Billing
  alias Streamix.Billing.Plan

  def mount(_params, _session, socket) do
    {:ok, assign(socket, current_path: "/admin/plans")}
  end

  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :new, _params) do
    changeset = Plan.changeset(%Plan{}, %{})

    socket
    |> assign(page_title: "Admin — Novo Plano")
    |> assign(plan: %Plan{})
    |> assign(form: to_form(changeset))
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    plan = Billing.get_plan!(id) |> Streamix.Repo.preload(:features)
    changeset = Plan.changeset(plan, %{})

    socket
    |> assign(page_title: "Admin — Editar #{plan.name}")
    |> assign(plan: plan)
    |> assign(form: to_form(changeset))
  end

  def handle_event("validate", %{"plan" => plan_params}, socket) do
    changeset =
      socket.assigns.plan
      |> Plan.changeset(plan_params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, form: to_form(changeset))}
  end

  def handle_event("save", %{"plan" => plan_params}, socket) do
    save_plan(socket, socket.assigns.live_action, plan_params)
  end

  defp save_plan(socket, :new, plan_params) do
    case Billing.create_plan(plan_params) do
      {:ok, _plan} ->
        {:noreply,
         socket
         |> put_flash(:info, "Plano criado com sucesso.")
         |> push_navigate(to: ~p"/admin/plans")}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  defp save_plan(socket, :edit, plan_params) do
    case Billing.update_plan(socket.assigns.plan, plan_params) do
      {:ok, _plan} ->
        {:noreply,
         socket
         |> put_flash(:info, "Plano atualizado com sucesso.")
         |> push_navigate(to: ~p"/admin/plans")}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  def render(assigns) do
    ~H"""
    <div id="admin-plan-form" class="space-y-6">
      <.admin_tabs current_path={@current_path} />

      <div class="max-w-2xl">
        <h1 class="text-xl font-semibold text-text-primary mb-6">
          {if @live_action == :new, do: "Novo Plano", else: "Editar #{@plan.name}"}
        </h1>

        <.form
          for={@form}
          id="plan-form"
          phx-change="validate"
          phx-submit="save"
          class="space-y-4"
        >
          <div class="grid grid-cols-1 sm:grid-cols-2 gap-4">
            <div>
              <.input field={@form[:name]} type="text" label="Nome" />
            </div>
            <div>
              <.input field={@form[:slug]} type="text" label="Slug" />
            </div>
          </div>

          <.input field={@form[:description]} type="textarea" label="Descricao" />

          <div class="grid grid-cols-1 sm:grid-cols-3 gap-4">
            <.input field={@form[:price_cents]} type="number" label="Preco (centavos)" />
            <.input
              field={@form[:currency]}
              type="select"
              label="Moeda"
              options={[{"Real (BRL)", "BRL"}, {"Dolar (USD)", "USD"}, {"Euro (EUR)", "EUR"}]}
            />
            <.input
              field={@form[:billing_interval]}
              type="select"
              label="Intervalo"
              options={[{"Dia", "day"}, {"Semana", "week"}, {"Mes", "month"}, {"Ano", "year"}]}
            />
          </div>

          <div class="flex gap-6">
            <.input field={@form[:grants_global_access]} type="checkbox" label="Acesso global" />
            <.input field={@form[:active]} type="checkbox" label="Ativo" />
          </div>

          <.input
            field={@form[:stripe_price_id]}
            type="text"
            label="Stripe Price ID"
            placeholder="price_..."
          />

          <.input
            field={@form[:trial_days]}
            type="number"
            label="Dias de trial grátis"
            min="0"
          />

          <fieldset class="surface-card p-4 space-y-4">
            <legend class="px-1 text-sm font-semibold text-text-primary">Features do plano</legend>

            <div class="grid grid-cols-1 sm:grid-cols-2 gap-3">
              <label class="flex items-center gap-2 text-sm text-text-secondary">
                <input
                  type="hidden"
                  name="plan[features][global_catalog]"
                  value="false"
                />
                <input
                  type="checkbox"
                  name="plan[features][global_catalog]"
                  value="true"
                  checked={feature_enabled?(@plan, "global_catalog", true)}
                  class="rounded border-border bg-surface text-brand focus:ring-brand"
                /> Catálogo global
              </label>

              <label class="flex items-center gap-2 text-sm text-text-secondary">
                <input
                  type="hidden"
                  name="plan[features][ai_recommendations]"
                  value="false"
                />
                <input
                  type="checkbox"
                  name="plan[features][ai_recommendations]"
                  value="true"
                  checked={feature_enabled?(@plan, "ai_recommendations", false)}
                  class="rounded border-border bg-surface text-brand focus:ring-brand"
                /> AI premium
              </label>

              <label class="flex items-center gap-2 text-sm text-text-secondary">
                <input
                  type="hidden"
                  name="plan[features][watch_party]"
                  value="false"
                />
                <input
                  type="checkbox"
                  name="plan[features][watch_party]"
                  value="true"
                  checked={feature_enabled?(@plan, "watch_party", false)}
                  class="rounded border-border bg-surface text-brand focus:ring-brand"
                /> Watch party
              </label>
            </div>

            <div class="grid grid-cols-1 sm:grid-cols-2 gap-4">
              <div>
                <label class="block text-sm font-medium text-text-primary mb-1">
                  Limite de providers
                </label>
                <input
                  type="number"
                  name="plan[features][max_providers]"
                  value={feature_limit(@plan, "max_providers")}
                  min="0"
                  class="w-full rounded-lg border border-border bg-surface px-3 py-2 text-sm text-text-primary focus:border-brand focus:outline-none focus:ring-2 focus:ring-brand/20"
                />
              </div>

              <div>
                <label class="block text-sm font-medium text-text-primary mb-1">
                  Streams simultâneos
                </label>
                <input
                  type="number"
                  name="plan[features][concurrent_streams]"
                  value={feature_limit(@plan, "concurrent_streams")}
                  min="0"
                  class="w-full rounded-lg border border-border bg-surface px-3 py-2 text-sm text-text-primary focus:border-brand focus:outline-none focus:ring-2 focus:ring-brand/20"
                />
              </div>
            </div>
          </fieldset>

          <div class="flex items-center gap-3 pt-4">
            <.button type="submit" phx-disable-with="Salvando...">
              {if @live_action == :new, do: "Criar plano", else: "Salvar alteracoes"}
            </.button>
            <.link
              navigate={~p"/admin/plans"}
              class="text-sm text-text-secondary hover:text-text-primary"
            >
              Cancelar
            </.link>
          </div>
        </.form>
      </div>
    </div>
    """
  end

  defp feature_enabled?(%Plan{features: features}, feature, default) when is_list(features) do
    case Enum.find(features, &(&1.feature == feature)) do
      nil -> default
      plan_feature -> plan_feature.enabled
    end
  end

  defp feature_enabled?(_plan, _feature, default), do: default

  defp feature_limit(%Plan{features: features}, feature) when is_list(features) do
    case Enum.find(features, &(&1.feature == feature)) do
      nil -> nil
      plan_feature -> plan_feature.limit
    end
  end

  defp feature_limit(_plan, _feature), do: nil
end
