defmodule StreamixWeb.User.SettingsLive do
  use StreamixWeb, :live_view

  alias Streamix.Accounts

  def mount(_params, _session, socket) do
    user = socket.assigns.current_scope.user

    socket =
      socket
      |> assign(page_title: "Configurações")
      |> assign(current_path: "/settings")
      |> assign(current_email: user.email)
      |> assign(email_form: to_form(Accounts.change_user_email(user), as: "user"))
      |> assign(password_form: to_form(Accounts.change_user_password(user), as: "user"))
      |> assign(settings_form: to_form(Accounts.change_user_settings(user), as: "user"))
      |> assign(trigger_submit: false)

    {:ok, socket}
  end

  def handle_event("validate_email", %{"user" => params}, socket) do
    user = socket.assigns.current_scope.user

    changeset =
      user
      |> Accounts.change_user_email(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, email_form: to_form(changeset, as: "user"))}
  end

  def handle_event("update_email", %{"user" => _params}, socket) do
    {:noreply,
     socket
     |> put_flash(:info, "A funcionalidade de alteração de email ainda não está implementada")}
  end

  def handle_event("validate_password", %{"user" => params}, socket) do
    user = socket.assigns.current_scope.user

    changeset =
      user
      |> Accounts.change_user_password(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, password_form: to_form(changeset, as: "user"))}
  end

  def handle_event("update_password", %{"user" => params}, socket) do
    user = socket.assigns.current_scope.user

    case Accounts.update_user_password(user, params) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Senha atualizada com sucesso")
         |> assign(trigger_submit: true)}

      {:error, changeset} ->
        {:noreply, assign(socket, password_form: to_form(changeset, as: "user"))}
    end
  end

  def handle_event("toggle_adult_content", _, socket) do
    user = socket.assigns.current_scope.user
    new_value = !user.show_adult_content

    case Accounts.update_user_settings(user, %{show_adult_content: new_value}) do
      {:ok, updated_user} ->
        {:noreply,
         socket
         |> assign(current_scope: %{socket.assigns.current_scope | user: updated_user})
         |> put_flash(:info, "Preferências atualizadas")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Erro ao atualizar preferências")}
    end
  end

  def handle_event("save_subtitle_preferences", %{"user" => attrs}, socket) do
    user = socket.assigns.current_scope.user

    params = %{
      "subtitles_enabled" => Map.get(attrs, "subtitles_enabled", "false"),
      "subtitle_language" => Map.get(attrs, "subtitle_language", "pt-BR")
    }

    update_settings(socket, user, params, "Preferências de legenda atualizadas")
  end

  def render(assigns) do
    ~H"""
    <div class="mx-auto w-full max-w-5xl space-y-4 sm:space-y-5">
      <div>
        <h1 class="text-2xl font-bold text-text-primary sm:text-3xl">Configurações</h1>
        <p class="mt-1 text-sm text-text-secondary sm:text-base">
          Gerencie as configurações da sua conta
        </p>
      </div>

      <div class="grid gap-4 lg:grid-cols-2 lg:items-start">
        <section class="rounded-lg border border-border bg-surface p-4 sm:p-5 lg:col-start-1 lg:row-start-1">
          <div class="mb-4">
            <h2 class="text-base font-semibold text-text-primary">Email</h2>
            <p class="mt-1 text-sm text-text-secondary">
              Atualize o endereço usado para entrar na sua conta.
            </p>
          </div>

          <.simple_form
            for={@email_form}
            id="email_form"
            phx-change="validate_email"
            phx-submit="update_email"
          >
            <.input
              field={@email_form[:email]}
              type="email"
              label="Email"
              required
              autocomplete="email"
            />
            <.input
              field={@email_form[:current_password]}
              type="password"
              label="Senha atual"
              required
              name="current_password"
              id="email_current_password"
              autocomplete="current-password"
            />

            <:actions>
              <.button type="submit" variant="primary" class="w-full sm:w-auto">
                Alterar Email
              </.button>
            </:actions>
          </.simple_form>
        </section>

        <section class="rounded-lg border border-border bg-surface p-4 sm:p-5 lg:col-start-2 lg:row-span-2 lg:row-start-1">
          <div class="mb-4">
            <h2 class="text-base font-semibold text-text-primary">Senha</h2>
            <p class="mt-1 text-sm text-text-secondary">
              Use uma senha forte para proteger seu acesso.
            </p>
          </div>

          <.simple_form
            for={@password_form}
            id="password_form"
            phx-change="validate_password"
            phx-submit="update_password"
            phx-trigger-action={@trigger_submit}
            action={~p"/login"}
            method="post"
          >
            <.input type="hidden" name={@password_form[:email].name} value={@current_email} />

            <.input
              field={@password_form[:password]}
              type="password"
              label="Nova senha"
              required
              autocomplete="new-password"
            />
            <p class="-mt-2 text-xs text-text-secondary">Mínimo de 12 caracteres</p>
            <.input
              field={@password_form[:password_confirmation]}
              type="password"
              label="Confirmar nova senha"
              required
              autocomplete="new-password"
            />
            <.input
              field={@password_form[:current_password]}
              type="password"
              label="Senha atual"
              required
              name="current_password"
              id="password_current_password"
              autocomplete="current-password"
            />

            <:actions>
              <.button type="submit" variant="primary" class="w-full sm:w-auto">
                Alterar Senha
              </.button>
            </:actions>
          </.simple_form>
        </section>
        <section class="rounded-lg border border-border bg-surface p-4 sm:p-5 lg:col-start-1 lg:row-start-2">
          <div class="flex flex-col gap-4 sm:flex-row sm:items-center sm:justify-between">
            <div>
              <h2 class="text-base font-semibold text-text-primary">Preferências de conteúdo</h2>
              <p class="mt-1 text-sm text-text-secondary">
                Mostrar categorias e conteúdo marcados como adulto (+18)
              </p>
            </div>
            <button
              id="adult-content-toggle"
              type="button"
              phx-click="toggle_adult_content"
              class="inline-flex size-11 shrink-0 cursor-pointer items-center justify-center rounded-full focus:outline-none focus:ring-2 focus:ring-brand focus:ring-offset-2 focus:ring-offset-surface"
              aria-label="Alternar conteúdo adulto"
              aria-pressed={to_string(@current_scope.user.show_adult_content)}
            >
              <span class={[
                "relative inline-flex h-6 w-11 rounded-full border-2 border-transparent transition-colors duration-200 ease-in-out",
                if(@current_scope.user.show_adult_content, do: "bg-brand", else: "bg-gray-600")
              ]}>
                <span class={[
                  "pointer-events-none inline-block h-5 w-5 transform rounded-full bg-white shadow ring-0 transition duration-200 ease-in-out",
                  if(@current_scope.user.show_adult_content,
                    do: "translate-x-5",
                    else: "translate-x-0"
                  )
                ]} />
              </span>
            </button>
          </div>
        </section>

        <section
          id="subtitle-preferences"
          class="rounded-lg border border-border bg-surface p-4 sm:p-5 lg:col-start-1 lg:row-start-3"
        >
          <div class="mb-4">
            <h2 class="text-base font-semibold text-text-primary">Legendas</h2>
            <p class="mt-1 text-sm text-text-secondary">
              Escolha o idioma e a ativação automática das legendas.
            </p>
          </div>

          <.form
            for={@settings_form}
            id="subtitle-preferences-form"
            phx-submit="save_subtitle_preferences"
            class="space-y-4"
          >
            <.input
              field={@settings_form[:subtitle_language]}
              type="select"
              label="Idioma preferido"
              options={[
                {"Português (Brasil)", "pt-BR"},
                {"Português (Portugal)", "pt-PT"},
                {"English", "en"},
                {"Español", "es"}
              ]}
            />
            <label class="flex min-h-11 cursor-pointer items-center gap-3 text-sm text-text-primary">
              <input
                type="checkbox"
                name={@settings_form[:subtitles_enabled].name}
                value="true"
                checked={@current_scope.user.subtitles_enabled}
                class="size-5 rounded border-border text-brand focus:ring-brand"
              /> Ativar legenda externa automaticamente quando disponível
            </label>
            <.button type="submit" variant="primary">Salvar legendas</.button>
          </.form>
        </section>

        <section
          id="pwa-app"
          class="rounded-lg border border-border bg-surface p-4 sm:p-5 lg:col-start-1 lg:row-start-4"
        >
          <div class="flex flex-col gap-4">
            <div>
              <h2 class="text-base font-semibold text-text-primary">App Streamix</h2>
              <p class="mt-1 text-sm text-text-secondary">
                Instale o app no celular ou repare o cache se ele ficar preso em uma versão antiga.
              </p>
            </div>

            <StreamixWeb.App.Pwa.install_action id="settings-pwa-install" />

            <div id="pwa-repair" phx-hook="PwaRepair" class="flex flex-col gap-3">
              <p data-pwa-repair-status class="text-sm text-text-secondary">
                Verificando cache local...
              </p>

              <div class="flex flex-col gap-2 sm:flex-row">
                <button
                  type="button"
                  data-pwa-repair-action="repair"
                  class="inline-flex min-h-11 items-center justify-center rounded-md bg-brand px-4 py-2 text-sm font-medium text-white transition-colors hover:bg-brand/90 disabled:cursor-wait disabled:opacity-70"
                >
                  Atualizar app e limpar cache
                </button>
                <button
                  type="button"
                  data-pwa-repair-action="clear"
                  class="inline-flex min-h-11 items-center justify-center rounded-md border border-border px-4 py-2 text-sm font-medium text-text-primary transition-colors hover:bg-surface-hover disabled:cursor-wait disabled:opacity-70"
                >
                  Limpar cache local
                </button>
              </div>
            </div>
          </div>
        </section>
      </div>
    </div>
    """
  end

  defp update_settings(socket, user, attrs, message) do
    case Accounts.update_user_settings(user, attrs) do
      {:ok, updated_user} ->
        {:noreply,
         socket
         |> assign(current_scope: %{socket.assigns.current_scope | user: updated_user})
         |> assign(
           settings_form: to_form(Accounts.change_user_settings(updated_user), as: "user")
         )
         |> put_flash(:info, message)}

      {:error, changeset} ->
        {:noreply,
         socket
         |> assign(settings_form: to_form(changeset, as: "user"))
         |> put_flash(:error, "Não foi possível salvar as preferências")}
    end
  end
end
