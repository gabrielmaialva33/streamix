defmodule StreamixWeb.Providers.ProviderFormComponent do
  @moduledoc """
  LiveComponent for creating and editing IPTV providers.
  """
  use StreamixWeb, :live_component

  alias Streamix.{Access, Iptv}

  def mount(socket) do
    {:ok,
     socket
     |> assign(testing: false)
     |> assign(saving: false)
     |> assign(test_result: nil)
     |> assign(tested_fingerprint: nil)}
  end

  def update(%{provider: provider} = assigns, socket) do
    changeset =
      if provider do
        Iptv.change_provider(provider)
      else
        Iptv.new_provider_changeset()
      end

    {:ok,
     socket
     |> assign(assigns)
     |> assign(
       can_publish_provider: Access.publishes_providers?(assigns.current_scope.user),
       form: to_form(changeset, as: "provider")
     )}
  end

  def handle_event("validate", %{"provider" => params}, socket) do
    changeset =
      if socket.assigns.provider do
        Iptv.change_provider(socket.assigns.provider, params)
      else
        Iptv.new_provider_changeset(params)
      end
      |> Map.put(:action, :validate)

    socket =
      socket
      |> assign(form: to_form(changeset, as: "provider"))
      |> maybe_clear_connection_test(params)

    {:noreply, socket}
  end

  def handle_event("test_connection", _params, %{assigns: %{testing: true}} = socket),
    do: {:noreply, socket}

  def handle_event("test_connection", _params, socket) do
    params = socket.assigns.form.params

    case connection_credentials(params) do
      {:ok, credentials} ->
        socket = assign(socket, testing: true, test_result: nil)

        {:noreply,
         start_async(socket, :connection_test, fn ->
           test_connection(credentials)
         end)}

      {:error, message} ->
        {:noreply, assign(socket, test_result: {:error, message})}
    end
  end

  def handle_event("save", %{"provider" => params}, socket) do
    params = process_visibility(params, socket)

    case socket.assigns.provider do
      nil -> start_provider_creation(socket, params)
      provider -> update_provider(socket, provider, params)
    end
  end

  def handle_async(:connection_test, {:ok, {:ok, account_info}}, socket) do
    fingerprint = connection_fingerprint(socket.assigns.form.params)

    {:noreply,
     assign(socket,
       testing: false,
       tested_fingerprint: fingerprint,
       test_result: {:ok, connection_summary(account_info)}
     )}
  end

  def handle_async(:connection_test, {:ok, {:error, reason}}, socket) do
    {:noreply,
     assign(socket,
       testing: false,
       tested_fingerprint: nil,
       test_result: {:error, format_error(reason)}
     )}
  end

  def handle_async(:connection_test, {:exit, _reason}, socket) do
    {:noreply,
     assign(socket,
       testing: false,
       tested_fingerprint: nil,
       test_result: {:error, "O teste de conexão foi interrompido. Tente novamente."}
     )}
  end

  def handle_async(:create_provider, {:ok, {:ok, provider}}, socket) do
    notify_parent({:saved, provider})
    {:noreply, assign(socket, saving: false)}
  end

  def handle_async(:create_provider, {:ok, {:error, %Ecto.Changeset{} = changeset}}, socket) do
    {:noreply,
     assign(socket,
       saving: false,
       form: to_form(changeset, as: "provider")
     )}
  end

  def handle_async(:create_provider, {:ok, {:error, reason}}, socket) do
    {:noreply,
     assign(socket,
       saving: false,
       test_result: {:error, format_error(reason)}
     )}
  end

  def handle_async(:create_provider, {:exit, _reason}, socket) do
    {:noreply,
     assign(socket,
       saving: false,
       test_result: {:error, "Não foi possível concluir o cadastro. Tente novamente."}
     )}
  end

  defp start_provider_creation(%{assigns: %{saving: true}} = socket, _params),
    do: {:noreply, socket}

  defp start_provider_creation(socket, params) do
    user_id = socket.assigns.current_scope.user.id
    fingerprint = connection_fingerprint(params)
    connection_already_tested? = fingerprint == socket.assigns.tested_fingerprint

    socket = assign(socket, saving: true, test_result: nil)

    {:noreply,
     start_async(socket, :create_provider, fn ->
       with :ok <- ensure_connection_tested(params, connection_already_tested?),
            {:ok, provider} <- Iptv.create_provider(user_id, params) do
         {:ok, provider}
       end
     end)}
  end

  defp update_provider(socket, provider, params) do
    user_id = socket.assigns.current_scope.user.id

    case Iptv.update_user_provider(user_id, provider, params) do
      {:ok, provider} ->
        notify_parent({:saved, provider})
        {:noreply, socket}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset, as: "provider"))}
    end
  end

  defp notify_parent(msg), do: send(self(), {__MODULE__, msg})

  defp format_error(:invalid_url), do: "Formato de URL inválido"
  defp format_error(:connection_refused), do: "Não foi possível conectar ao servidor"
  defp format_error(:timeout), do: "Tempo limite de conexão esgotado"
  defp format_error(:invalid_credentials), do: "Usuário ou senha inválidos"
  defp format_error(:not_found), do: "Servidor não encontrado"
  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(_), do: "Ocorreu um erro desconhecido"

  defp test_connection(%{url: url, username: username, password: password}) do
    Iptv.test_connection(url, username, password)
  end

  defp ensure_connection_tested(_params, true), do: :ok

  defp ensure_connection_tested(params, false) do
    with {:ok, credentials} <- connection_credentials(params),
         {:ok, _account_info} <- test_connection(credentials) do
      :ok
    end
  end

  defp connection_credentials(params) do
    credentials = %{
      url: normalized_credential(params["url"]),
      username: normalized_credential(params["username"]),
      password: normalized_credential(params["password"])
    }

    if Enum.all?(Map.values(credentials), &(&1 != "")) do
      {:ok, credentials}
    else
      {:error, "Preencha URL, usuário e senha antes de testar a conexão."}
    end
  end

  defp normalized_credential(value) when is_binary(value), do: String.trim(value)
  defp normalized_credential(_value), do: ""

  defp connection_fingerprint(params) do
    case connection_credentials(params) do
      {:ok, credentials} ->
        credentials
        |> Map.take([:url, :username, :password])
        |> :erlang.term_to_binary()
        |> then(&:crypto.hash(:sha256, &1))

      {:error, _message} ->
        nil
    end
  end

  defp maybe_clear_connection_test(socket, params) do
    if connection_fingerprint(params) == socket.assigns.tested_fingerprint do
      socket
    else
      assign(socket, tested_fingerprint: nil, test_result: nil)
    end
  end

  defp connection_summary(account_info) when is_map(account_info) do
    info = Map.get(account_info, "user_info", account_info)

    %{
      username: text_value(info, ["username", :username]),
      status: text_value(info, ["status", :status, "auth", :auth]),
      expires_at: expiration_label(info),
      max_connections: integer_value(info, ["max_connections", :max_connections]),
      active_connections: integer_value(info, ["active_cons", :active_cons, "active_connections"])
    }
  end

  defp connection_summary(_account_info), do: %{}

  defp text_value(map, keys) do
    Enum.find_value(keys, fn key ->
      case Map.get(map, key) do
        value when is_binary(value) and value != "" -> value
        value when is_integer(value) -> Integer.to_string(value)
        _ -> nil
      end
    end)
  end

  defp integer_value(map, keys) do
    case text_value(map, keys) do
      nil -> nil
      value -> parse_integer(value)
    end
  end

  defp expiration_label(info) do
    case integer_value(info, ["exp_date", :exp_date, "expiration", :expiration]) do
      nil -> nil
      0 -> "Sem expiração informada"
      unix -> unix |> DateTime.from_unix() |> format_expiration()
    end
  end

  defp format_expiration({:ok, datetime}), do: Calendar.strftime(datetime, "%d/%m/%Y")
  defp format_expiration(_result), do: nil

  defp parse_integer(value) when is_integer(value), do: value

  defp parse_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} -> parsed
      _ -> nil
    end
  end

  defp parse_integer(_value), do: nil

  # Check if provider is public (either from form params or existing data)
  defp public?(form) do
    case form.params["is_public"] do
      "true" -> true
      "false" -> false
      nil -> form.data && form.data.visibility == :public
      _ -> false
    end
  end

  # A regular user cannot promote a private provider to the shared catalog.
  # Existing public rows remain public when edited so a permission change does
  # not silently alter production visibility.
  defp process_visibility(params, socket) do
    requested_public? = params["is_public"] in ["true", true]
    existing_public? = socket.assigns.provider && socket.assigns.provider.visibility == :public

    visibility =
      if (socket.assigns.can_publish_provider and requested_public?) or existing_public?,
        do: :public,
        else: :private

    params
    |> Map.put("visibility", visibility)
    |> Map.delete("is_public")
  end

  def render(assigns) do
    ~H"""
    <div>
      <h3 class="text-base sm:text-lg font-bold mb-3 sm:mb-4">
        {if @provider, do: "Editar Provedor", else: "Adicionar Provedor"}
      </h3>

      <.simple_form
        for={@form}
        id="provider-form"
        phx-change="validate"
        phx-submit="save"
        phx-target={@myself}
      >
        <.input field={@form[:name]} label="Nome" placeholder="Meu Serviço IPTV" required />
        <.input
          field={@form[:url]}
          label="URL do Servidor"
          placeholder="http://exemplo.com:8080"
          required
        />
        <.input field={@form[:username]} label="Usuário" required />
        <.input field={@form[:password]} type="password" label="Senha" required />

        <div :if={@can_publish_provider} class="flex items-start gap-3 py-2">
          <input
            type="checkbox"
            id="provider_is_public"
            name="provider[is_public]"
            checked={public?(@form)}
            class="mt-0.5 size-5 rounded border-border text-brand focus:ring-brand"
          />
          <label for="provider_is_public" class="text-sm text-text-secondary">
            <span class="font-medium text-text-primary">Compartilhar no catálogo público</span>
            <span class="block text-xs">
              Outros usuários poderão descobrir e reproduzir o conteúdo conforme as regras de acesso.
            </span>
          </label>
        </div>

        <div
          :if={!@can_publish_provider}
          class="flex items-start gap-2 rounded-lg border border-border bg-surface-hover/45 p-3 text-xs text-text-secondary"
        >
          <.icon name="hero-lock-closed" class="mt-0.5 size-4 shrink-0" />
          <p>
            Novos provedores são privados. A publicação no catálogo compartilhado exige permissão administrativa.
          </p>
        </div>

        <div
          :if={@test_result}
          class={[
            "alert mb-4",
            elem(@test_result, 0) == :ok && "alert-success",
            elem(@test_result, 0) == :error && "alert-error"
          ]}
        >
          <%= case @test_result do %>
            <% {:ok, info} -> %>
              <div class="flex w-full items-start gap-2">
                <.icon name="hero-check-circle" class="mt-0.5 size-5 shrink-0" />
                <div class="min-w-0 flex-1">
                  <p class="font-semibold">Conexão validada</p>
                  <dl class="mt-2 grid gap-x-4 gap-y-1 text-xs sm:grid-cols-2">
                    <div :if={info.username}>
                      <dt class="text-text-muted">Conta</dt>
                      <dd class="truncate font-medium">{info.username}</dd>
                    </div>
                    <div :if={info.status}>
                      <dt class="text-text-muted">Status</dt>
                      <dd class="font-medium">{info.status}</dd>
                    </div>
                    <div :if={info.expires_at}>
                      <dt class="text-text-muted">Expiração</dt>
                      <dd class="font-medium">{info.expires_at}</dd>
                    </div>
                    <div :if={info.max_connections}>
                      <dt class="text-text-muted">Conexões</dt>
                      <dd class="font-medium">
                        {info.active_connections || 0}/{info.max_connections}
                      </dd>
                    </div>
                  </dl>
                </div>
              </div>
            <% {:error, msg} -> %>
              <.icon name="hero-x-circle" class="size-5" />
              <span>{msg}</span>
          <% end %>
        </div>

        <:actions>
          <div class="flex flex-col-reverse sm:flex-row gap-2 sm:gap-3 w-full sm:w-auto">
            <button
              type="button"
              phx-click="test_connection"
              phx-target={@myself}
              disabled={@testing || @saving}
              class="inline-flex items-center justify-center gap-2 px-4 py-2.5 sm:py-2 text-text-secondary hover:text-text-primary hover:bg-surface-hover font-medium rounded-lg disabled:opacity-50 transition-colors"
            >
              <.icon
                :if={@testing}
                name="hero-arrow-path"
                class="size-4 animate-spin"
              />
              <.icon :if={!@testing} name="hero-signal" class="size-4" /> Testar Conexão
            </button>
            <.button
              type="submit"
              variant="primary"
              class="w-full justify-center sm:w-auto"
              disabled={@testing || @saving}
            >
              <.icon :if={@saving} name="hero-arrow-path" class="size-4 animate-spin" />
              <span>
                <%= cond do %>
                  <% @saving -> %>
                    Validando e adicionando…
                  <% @provider -> %>
                    Atualizar
                  <% true -> %>
                    Adicionar Provedor
                <% end %>
              </span>
            </.button>
          </div>
        </:actions>
      </.simple_form>
    </div>
    """
  end
end
