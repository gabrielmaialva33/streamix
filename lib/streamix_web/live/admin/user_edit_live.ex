defmodule StreamixWeb.Admin.UserEditLive do
  use StreamixWeb, :live_view

  import StreamixWeb.AdminComponents

  alias Streamix.{Accounts, Billing}

  def mount(%{"id" => id}, _session, socket) do
    user = Accounts.get_user!(id)
    active_sub = Billing.active_subscription_for_user(user)
    plans = Billing.list_active_plans()
    user = Streamix.Repo.preload(user, :role)
    role_changeset = Ecto.Changeset.change(user, %{})

    socket =
      socket
      |> assign(
        page_title: "Admin — #{user.email}",
        current_path: "/admin/users",
        user: user,
        active_sub: active_sub,
        plans: plans,
        role_form: to_form(role_changeset, as: :user),
        sub_form: to_form(%{"plan_id" => "", "expires_at" => ""}, as: :subscription)
      )

    {:ok, socket}
  end

  def handle_event("save_role", %{"user" => %{"role" => role_name}}, socket) do
    case Accounts.update_user_role(socket.assigns.user, role_name) do
      {:ok, updated_user} ->
        updated_user = Streamix.Repo.preload(updated_user, :role, force: true)

        {:noreply,
         socket
         |> assign(user: updated_user)
         |> assign(role_form: to_form(Ecto.Changeset.change(updated_user, %{}), as: :user))
         |> put_flash(:info, "Role atualizado para #{role_name}.")}

      {:error, changeset} ->
        {:noreply, assign(socket, role_form: to_form(changeset, as: :user))}
    end
  end

  def handle_event("save_settings", %{"user" => attrs}, socket) do
    show_adult = Map.get(attrs, "show_adult_content", "false") == "true"

    case Accounts.update_user_settings_admin(socket.assigns.user, %{
           show_adult_content: show_adult
         }) do
      {:ok, updated_user} ->
        {:noreply,
         socket
         |> assign(user: updated_user)
         |> put_flash(:info, "Configurações atualizadas.")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Erro ao atualizar configurações.")}
    end
  end

  def handle_event("create_subscription", %{"subscription" => params}, socket) do
    user = socket.assigns.user
    plan = Billing.get_plan!(params["plan_id"])
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    expires_at =
      case params["expires_at"] do
        "" ->
          nil

        nil ->
          nil

        dt_string ->
          case DateTime.from_iso8601(dt_string <> ":00Z") do
            {:ok, dt, _} -> dt
            _ -> nil
          end
      end

    case Billing.create_manual_subscription(user, plan, %{
           status: "active",
           starts_at: now,
           expires_at: expires_at
         }) do
      {:ok, _sub} ->
        active_sub = Billing.active_subscription_for_user(user)

        {:noreply,
         socket
         |> assign(active_sub: active_sub)
         |> put_flash(:info, "Subscription criada com sucesso.")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Erro ao criar subscription.")}
    end
  end

  def handle_event("cancel_subscription", _params, socket) do
    if socket.assigns.active_sub do
      Billing.cancel_subscription!(socket.assigns.active_sub)
      user = socket.assigns.user

      {:noreply,
       socket
       |> assign(active_sub: Billing.active_subscription_for_user(user))
       |> put_flash(:info, "Subscription cancelada.")}
    else
      {:noreply, socket}
    end
  end

  def render(assigns) do
    ~H"""
    <div id="admin-user-edit" class="space-y-6">
      <.admin_tabs current_path={@current_path} />

      <div class="flex items-center gap-3">
        <.link navigate={~p"/admin/users"} class="text-text-secondary hover:text-text-primary">
          <.icon name="hero-arrow-left" class="size-5" />
        </.link>
        <h1 class="text-xl font-semibold text-text-primary">{@user.email}</h1>
        <.status_badge status={@user.role.name} />
      </div>

      <div class="grid grid-cols-1 lg:grid-cols-2 gap-6">
        <%!-- User details --%>
        <section class="rounded-2xl border border-border bg-surface p-5 space-y-5">
          <h2 class="text-lg font-semibold text-text-primary">Detalhes do Usuário</h2>

          <div class="text-sm space-y-2">
            <p>
              <span class="text-text-muted">Email:</span>
              <span class="text-text-primary">{@user.email}</span>
            </p>
            <p>
              <span class="text-text-muted">Registrado:</span>
              <span class="text-text-primary">
                {Calendar.strftime(@user.inserted_at, "%d/%m/%Y %H:%M")}
              </span>
            </p>
          </div>

          <.form for={@role_form} id="user-role-form" phx-submit="save_role" class="space-y-3">
            <.input
              name="user[role]"
              type="select"
              label="Role"
              value={@user.role.name}
              options={[{"Admin", "admin"}, {"Customer", "customer"}, {"Moderator", "moderator"}]}
            />
            <.button type="submit" phx-disable-with="Salvando...">Salvar role</.button>
          </.form>

          <.form
            for={%{}}
            id="user-settings-form"
            phx-submit="save_settings"
            class="space-y-3"
          >
            <.input
              name="user[show_adult_content]"
              type="checkbox"
              label="Conteúdo adulto"
              checked={@user.show_adult_content}
              value="true"
            />
            <.button type="submit" phx-disable-with="Salvando...">Salvar configurações</.button>
          </.form>
        </section>

        <%!-- Subscription management --%>
        <section class="rounded-2xl border border-border bg-surface p-5 space-y-5">
          <h2 class="text-lg font-semibold text-text-primary">Subscription</h2>

          <%= if @active_sub do %>
            <div class="rounded-xl border border-brand/20 bg-brand/5 p-4 space-y-2">
              <div class="flex items-center justify-between">
                <span class="font-medium text-text-primary">{@active_sub.plan.name}</span>
                <.status_badge status={@active_sub.status} />
              </div>
              <div class="text-sm text-text-secondary space-y-1">
                <p :if={@active_sub.starts_at}>
                  Início: {Calendar.strftime(@active_sub.starts_at, "%d/%m/%Y %H:%M")}
                </p>
                <p :if={@active_sub.expires_at}>
                  Expira: {Calendar.strftime(@active_sub.expires_at, "%d/%m/%Y %H:%M")}
                </p>
                <p :if={is_nil(@active_sub.expires_at)} class="text-green-400">
                  Sem expiração (indefinida)
                </p>
              </div>
              <button
                id="cancel-subscription-btn"
                phx-click="cancel_subscription"
                data-confirm="Tem certeza que quer cancelar esta subscription?"
                class="mt-2 text-sm text-red-400 hover:text-red-300 font-medium"
              >
                Cancelar subscription
              </button>
            </div>
          <% else %>
            <p class="text-sm text-text-secondary">Nenhuma subscription ativa.</p>

            <.form
              for={@sub_form}
              id="subscription-form"
              phx-submit="create_subscription"
              class="space-y-3"
            >
              <.input
                field={@sub_form[:plan_id]}
                type="select"
                label="Plano"
                prompt="Selecione um plano"
                options={Enum.map(@plans, &{&1.name, &1.id})}
              />
              <.input
                field={@sub_form[:expires_at]}
                type="datetime-local"
                label="Expira em (opcional)"
              />
              <.button type="submit" phx-disable-with="Criando...">
                Criar subscription manual
              </.button>
            </.form>
          <% end %>
        </section>
      </div>
    </div>
    """
  end
end
