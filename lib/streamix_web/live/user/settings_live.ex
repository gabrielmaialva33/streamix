defmodule StreamixWeb.User.SettingsLive do
  use StreamixWeb, :live_view

  alias Streamix.Accounts
  alias StreamixWeb.Locale

  def mount(_params, _session, socket) do
    user = socket.assigns.current_scope.user

    socket =
      socket
      |> assign(page_title: gettext("Configurações"))
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

  def handle_event("save_locale", %{"user" => attrs}, socket) do
    user = socket.assigns.current_scope.user
    requested_locale = Map.get(attrs, "locale", Locale.default())

    case Accounts.update_user_settings(user, %{locale: requested_locale}) do
      {:ok, updated_user} ->
        locale = Locale.put(updated_user.locale)

        {:noreply,
         socket
         |> assign(
           current_scope: %{socket.assigns.current_scope | user: updated_user},
           locale: locale,
           html_lang: Locale.html_lang(locale),
           page_title: gettext("Configurações"),
           settings_form: to_form(Accounts.change_user_settings(updated_user), as: "user")
         )
         |> put_flash(:info, gettext("Idioma da interface atualizado"))}

      {:error, changeset} ->
        {:noreply,
         socket
         |> assign(settings_form: to_form(changeset, as: "user"))
         |> put_flash(:error, gettext("Não foi possível atualizar o idioma"))}
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
        <h1 class="text-2xl font-bold text-text-primary sm:text-3xl">{gettext("Configurações")}</h1>
        <p class="mt-1 text-sm text-text-secondary sm:text-base">
          {gettext("Gerencie as configurações da sua conta")}
        </p>
      </div>

      <div class="grid gap-4 lg:grid-cols-2 lg:items-start">
        <section
          id="account-settings"
          class="rounded-lg border border-border bg-surface p-4 sm:p-5"
        >
          <div class="mb-5">
            <h2 class="text-lg font-semibold text-text-primary">Conta</h2>
            <p class="mt-1 text-sm text-text-secondary">
              Gerencie as credenciais usadas para acessar o Streamix.
            </p>
          </div>

          <div id="email-settings">
            <div class="mb-4">
              <h3 class="text-base font-semibold text-text-primary">Email</h3>
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
          </div>

          <div id="password-settings" class="mt-6 border-t border-border pt-5">
            <div class="mb-4">
              <h3 class="text-base font-semibold text-text-primary">Senha</h3>
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
          </div>
        </section>

        <section
          id="interface-preferences"
          class="rounded-lg border border-border bg-surface p-4 sm:p-5"
        >
          <div class="mb-4">
            <h2 class="text-lg font-semibold text-text-primary">{gettext("Interface")}</h2>
            <p class="mt-1 text-sm text-text-secondary">
              {gettext("Escolha o idioma usado na navegação e nas mensagens principais.")}
            </p>
          </div>

          <.form
            for={@settings_form}
            id="locale-preferences-form"
            phx-submit="save_locale"
            class="space-y-4"
          >
            <.input
              field={@settings_form[:locale]}
              type="select"
              label={gettext("Idioma da interface")}
              options={@locale_options}
            />
            <.button type="submit" variant="primary">
              {gettext("Salvar idioma")}
            </.button>
          </.form>
        </section>

        <section
          id="playback-preferences"
          class="rounded-lg border border-border bg-surface p-4 sm:p-5"
        >
          <div class="mb-5">
            <h2 class="text-lg font-semibold text-text-primary">Reprodução</h2>
            <p class="mt-1 text-sm text-text-secondary">
              Ajuste o catálogo e o comportamento padrão do player.
            </p>
          </div>

          <div id="content-preferences">
            <div class="flex flex-col gap-4 sm:flex-row sm:items-center sm:justify-between">
              <div>
                <h3 class="text-base font-semibold text-text-primary">
                  Preferências de conteúdo
                </h3>
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
          </div>

          <div
            id="subtitle-preferences"
            class="mt-6 border-t border-border pt-5"
          >
            <div class="mb-4">
              <h3 class="text-base font-semibold text-text-primary">Legendas</h3>
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
              <.input
                field={@settings_form[:subtitles_enabled]}
                type="checkbox"
                label="Ativar legenda externa automaticamente quando disponível"
                class="size-5 rounded border-border bg-surface text-brand focus:ring-2 focus:ring-brand focus:ring-offset-background"
              />
              <.button type="submit" variant="primary">Salvar legendas</.button>
            </.form>
          </div>
        </section>

        <section
          id="pwa-app"
          class="rounded-lg border border-border bg-surface p-4 sm:p-5 lg:col-span-2"
        >
          <div class="flex flex-col gap-4">
            <div>
              <h2 class="text-base font-semibold text-text-primary">App Streamix</h2>
              <p class="mt-1 text-sm text-text-secondary">
                Instale o app no celular ou repare o cache se ele ficar preso em uma versão antiga.
              </p>
            </div>

            <StreamixWeb.App.Pwa.install_action id="settings-pwa-install" />

            <details
              id="pwa-diagnostics"
              class="group overflow-hidden rounded-lg border border-border bg-surface-elevated/40"
            >
              <summary class="flex min-h-11 cursor-pointer list-none items-center justify-between gap-3 px-3 py-2.5 text-sm font-medium text-text-primary">
                <span class="flex items-center gap-2">
                  <.icon name="hero-wrench-screwdriver" class="size-4 text-text-secondary" />
                  Diagnóstico do app
                </span>
                <.icon
                  name="hero-chevron-down"
                  class="size-4 text-text-secondary transition-transform group-open:rotate-180"
                />
              </summary>

              <div
                id="pwa-repair"
                phx-hook="PwaRepair"
                class="flex flex-col gap-3 border-t border-border p-3"
              >
                <p
                  data-pwa-repair-status
                  aria-live="polite"
                  class="text-sm text-text-secondary"
                >
                  Verificando cache local...
                </p>

                <div class="grid gap-2 sm:grid-cols-2">
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
                  <button
                    type="button"
                    data-pwa-repair-action="sync"
                    class="inline-flex min-h-11 items-center justify-center rounded-md border border-border px-4 py-2 text-sm font-medium text-text-primary transition-colors hover:bg-surface-hover disabled:cursor-wait disabled:opacity-70 sm:col-span-2"
                  >
                    Tentar sincronização offline
                  </button>
                </div>
              </div>
            </details>
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
