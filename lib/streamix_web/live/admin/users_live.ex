defmodule StreamixWeb.Admin.UsersLive do
  use StreamixWeb, :live_view

  import StreamixWeb.AdminComponents

  alias Streamix.{Accounts, Billing}

  def mount(_params, _session, socket) do
    users = Accounts.list_users(page: 1, per_page: 20)

    socket =
      socket
      |> assign(page_title: "Admin — Usuários", current_path: "/admin/users")
      |> assign(users: users, search: "", page: 1)

    {:ok, socket}
  end

  def handle_event("search", %{"search" => search}, socket) do
    users = Accounts.list_users(search: search, page: 1, per_page: 20)

    {:noreply, assign(socket, users: users, search: search, page: 1)}
  end

  def handle_event("load_more", _params, socket) do
    next_page = socket.assigns.page + 1
    users = Accounts.list_users(search: socket.assigns.search, page: next_page, per_page: 20)

    {:noreply, assign(socket, users: socket.assigns.users ++ users, page: next_page)}
  end

  def render(assigns) do
    ~H"""
    <div id="admin-users" class="space-y-6">
      <.admin_tabs current_path={@current_path} />

      <div class="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between sm:gap-4">
        <h1 class="text-xl font-semibold text-text-primary">Usuários</h1>
        <.form for={%{}} id="search-form" phx-submit="search" class="w-full sm:max-w-sm">
          <.input
            name="search"
            value={@search}
            type="text"
            placeholder="Buscar por email..."
            phx-debounce="300"
          />
        </.form>
      </div>

      <div
        :if={@users != []}
        class="surface-card"
      >
        <div data-admin-table="users" class="overflow-x-auto">
          <table class="w-full min-w-[44rem] text-sm">
            <thead>
              <tr class="border-b border-border bg-surface-hover/50 text-left text-text-muted">
                <th class="px-4 py-3">Email</th>
                <th class="px-4 py-3">Perfil</th>
                <th class="px-4 py-3">Assinatura</th>
                <th class="px-4 py-3">Registrado</th>
                <th class="px-4 py-3"></th>
              </tr>
            </thead>
            <tbody>
              <tr :for={user <- @users} class="border-b border-border/50 hover:bg-surface-hover/30">
                <td class="px-4 py-3 text-text-primary">{user.email}</td>
                <td class="px-4 py-3"><.status_badge status={user.role.name} /></td>
                <td class="px-4 py-3">
                  <.status_badge status={subscription_label(user)} />
                </td>
                <td class="px-4 py-3 text-text-secondary">
                  {Calendar.strftime(user.inserted_at, "%d/%m/%Y")}
                </td>
                <td class="px-4 py-3">
                  <.link
                    navigate={~p"/admin/users/#{user.id}"}
                    class="inline-flex min-h-11 items-center text-sm text-brand hover:underline"
                  >
                    Editar
                  </.link>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>

      <div
        :if={@users == []}
        class="rounded-lg border border-dashed border-border bg-surface/50 p-8 text-center"
      >
        <.icon name="hero-users" class="mx-auto mb-3 size-10 text-text-muted" />
        <h3 class="text-lg font-semibold text-text-primary">Nenhum usuário encontrado</h3>
      </div>
    </div>
    """
  end

  defp subscription_label(user) do
    if Billing.subscribed?(user), do: "active", else: "expired"
  end
end
