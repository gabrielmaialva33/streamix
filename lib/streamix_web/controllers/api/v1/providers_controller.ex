defmodule StreamixWeb.Api.V1.ProvidersController do
  @moduledoc """
  REST API for user's private IPTV provider management.

  Allows users to add, list, delete, and trigger sync of their
  personal IPTV providers. System/global providers are excluded.
  """
  use StreamixWeb, :controller

  alias Streamix.Accounts
  alias Streamix.Iptv.Providers

  plug :authenticate

  @doc """
  GET /api/v1/providers
  Lists user's private providers (excludes system providers).
  """
  def index(conn, _params) do
    user = conn.assigns.current_user
    providers = Providers.list(user.id)

    json(conn, %{
      providers: Enum.map(providers, &serialize/1)
    })
  end

  @doc """
  POST /api/v1/providers
  Creates a new private provider for the user.
  Body: { "name": "My IPTV", "url": "http://...", "username": "...", "password": "..." }
  """
  def create(conn, %{"name" => _, "url" => _, "username" => _, "password" => _} = params) do
    user = conn.assigns.current_user

    attrs = %{
      name: params["name"],
      url: params["url"],
      username: params["username"],
      password: params["password"],
      provider_type: :xtream,
      visibility: :private
    }

    case Providers.create_for_user(user.id, attrs) do
      {:ok, provider} ->
        conn
        |> put_status(:created)
        |> json(serialize(provider))

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: %{code: "validation_failed", message: format_errors(changeset)}})
    end
  end

  def create(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{
      error: %{code: "missing_params", message: "name, url, username, and password required"}
    })
  end

  @doc """
  DELETE /api/v1/providers/:id
  Deletes a user's private provider.
  """
  def delete(conn, %{"id" => id}) do
    user = conn.assigns.current_user

    case Providers.get_user_provider(user.id, String.to_integer(id)) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: %{code: "not_found", message: "Provider not found"}})

      provider ->
        case Providers.delete(provider) do
          {:ok, _} ->
            send_resp(conn, 204, "")

          {:error, _} ->
            conn
            |> put_status(:unprocessable_entity)
            |> json(%{error: %{code: "delete_failed", message: "Failed to delete provider"}})
        end
    end
  end

  @doc """
  POST /api/v1/providers/:id/sync
  Triggers async sync for a user's provider.
  """
  def sync(conn, %{"id" => id}) do
    user = conn.assigns.current_user

    case Providers.get_user_provider(user.id, String.to_integer(id)) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: %{code: "not_found", message: "Provider not found"}})

      provider ->
        case Providers.async_sync(provider) do
          {:ok, _job} ->
            conn
            |> put_status(:accepted)
            |> json(%{status: "sync_started", provider_id: provider.id})

          {:error, reason} ->
            conn
            |> put_status(:unprocessable_entity)
            |> json(%{error: %{code: "sync_failed", message: inspect(reason)}})
        end
    end
  end

  # Serializer — never exposes credentials
  defp serialize(provider) do
    %{
      id: provider.id,
      name: provider.name,
      url: provider.url,
      provider_type: provider.provider_type,
      is_active: provider.is_active,
      last_synced_at: provider.last_synced_at,
      channels_count: provider.channels_count || 0,
      movies_count: provider.movies_count || 0,
      series_count: provider.series_count || 0,
      inserted_at: provider.inserted_at
    }
  end

  # Auth plug
  defp authenticate(conn, _opts) do
    with token_str when is_binary(token_str) <- get_bearer_token(conn),
         {:ok, token} <- Base.url_decode64(token_str),
         {user, _inserted_at} <- Accounts.get_user_by_session_token(token) do
      assign(conn, :current_user, user)
    else
      _ ->
        conn
        |> put_status(:unauthorized)
        |> json(%{error: %{code: "unauthorized", message: "Bearer token required"}})
        |> halt()
    end
  end

  defp get_bearer_token(conn) do
    case Plug.Conn.get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> token
      _ -> nil
    end
  end

  defp format_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
    |> Enum.map_join("; ", fn {field, errors} -> "#{field}: #{Enum.join(errors, ", ")}" end)
  end
end
