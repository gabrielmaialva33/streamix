defmodule StreamixWeb.Api.V1.ProvidersController do
  @moduledoc """
  REST API for user's private IPTV provider management.

  Allows users to add, list, delete, and trigger sync of their
  personal IPTV providers. System/global providers are excluded.
  """
  use StreamixWeb, :controller

  use OpenApiSpex.ControllerSpecs

  action_fallback StreamixWeb.Api.V1.FallbackController

  alias StreamixWeb.Api.V1.Operations

  operation :index,
            Operations.build(
              "providers.index",
              "List personal providers",
              "PersonalProvidersResponse",
              security: Operations.authenticated()
            )

  operation :create,
            Operations.build("providers.create", "Create a personal provider", "PersonalProvider",
              status: :created,
              body: "ProviderRequest",
              security: Operations.authenticated(),
              errors: [:unprocessable_entity]
            )

  operation :delete,
            Operations.build("providers.delete", "Delete a personal provider", nil,
              status: :no_content,
              parameters: [Operations.path(:id, :integer)],
              security: Operations.authenticated(),
              errors: [:not_found, :unprocessable_entity]
            )

  operation :sync,
            Operations.build(
              "providers.sync",
              "Schedule provider synchronization",
              "ProviderSyncResponse",
              status: :accepted,
              parameters: [Operations.path(:id, :integer)],
              security: Operations.authenticated(),
              errors: [:not_found, :internal_server_error]
            )

  import StreamixWeb.Helpers.Params, only: [parse_positive_integer: 1]
  alias StreamixWeb.Api.V1.Response

  plug StreamixWeb.Plugs.BearerAuth

  @doc """
  GET /api/v1/providers
  Lists user's private providers (excludes system providers).
  """
  def index(conn, _params) do
    user = conn.assigns.current_scope.user
    providers = Streamix.Providers.list_providers(user.id)

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
    user = conn.assigns.current_scope.user

    attrs = %{
      name: params["name"],
      url: params["url"],
      username: params["username"],
      password: params["password"],
      provider_type: :xtream,
      visibility: :private
    }

    case Streamix.Providers.create_provider(user.id, attrs) do
      {:ok, provider} ->
        conn
        |> put_status(:created)
        |> json(serialize(provider))

      {:error, changeset} ->
        Response.error(
          conn,
          :unprocessable_entity,
          "validation_failed",
          Response.changeset_message(changeset)
        )
    end
  end

  def create(conn, _params) do
    Response.error(
      conn,
      :bad_request,
      "missing_params",
      "name, url, username, and password required"
    )
  end

  @doc """
  DELETE /api/v1/providers/:id
  Deletes a user's private provider.
  """
  def delete(conn, %{"id" => id}) do
    user = conn.assigns.current_scope.user

    with {:ok, provider_id} <- parse_positive_integer(id),
         provider when not is_nil(provider) <-
           Streamix.Providers.get_user_provider(user.id, provider_id) do
      case Streamix.Providers.delete_provider(provider) do
        {:ok, _} ->
          send_resp(conn, :no_content, "")

        {:error, _} ->
          Response.error(
            conn,
            :unprocessable_entity,
            "delete_failed",
            "Failed to delete provider"
          )
      end
    else
      :error ->
        {:error, :invalid_id, "Invalid provider id"}

      nil ->
        Response.error(conn, :not_found, "not_found", "Provider not found")
    end
  end

  @doc """
  POST /api/v1/providers/:id/sync
  Triggers async sync for a user's provider.
  """
  def sync(conn, %{"id" => id}) do
    user = conn.assigns.current_scope.user

    with {:ok, provider_id} <- parse_positive_integer(id),
         provider when not is_nil(provider) <-
           Streamix.Providers.get_user_provider(user.id, provider_id) do
      case Streamix.Providers.async_sync_provider(provider) do
        {:ok, _job} ->
          conn
          |> put_status(:accepted)
          |> json(%{status: "sync_started", provider_id: provider.id})

        {:error, reason} ->
          Response.internal_error(
            conn,
            :unprocessable_entity,
            "sync_failed",
            "Failed to schedule provider sync",
            reason
          )
      end
    else
      :error ->
        {:error, :invalid_id, "Invalid provider id"}

      nil ->
        Response.error(conn, :not_found, "not_found", "Provider not found")
    end
  end

  # Serializer — never exposes credentials
  defp serialize(provider) do
    %{
      id: provider.id,
      name: provider.name,
      url: public_provider_url(provider.url),
      provider_type: provider.provider_type,
      is_active: provider.is_active,
      last_synced_at: latest_sync_at(provider),
      channels_count: provider.live_channels_count || 0,
      movies_count: provider.movies_count || 0,
      series_count: provider.series_count || 0,
      inserted_at: provider.inserted_at
    }
  end

  defp latest_sync_at(provider) do
    provider
    |> Map.take([:live_synced_at, :vod_synced_at, :series_synced_at, :epg_synced_at])
    |> Map.values()
    |> Enum.reject(&is_nil/1)
    |> Enum.max_by(&DateTime.to_unix(&1, :microsecond), fn -> nil end)
  end

  # Older rows may predate the URL userinfo validation. Keep the base URL
  # useful to clients without ever reflecting embedded/query credentials.
  defp public_provider_url(url) when is_binary(url) do
    case URI.new(url) do
      {:ok, uri} -> URI.to_string(%{uri | userinfo: nil, query: nil, fragment: nil})
      {:error, _reason} -> nil
    end
  end

  defp public_provider_url(_url), do: nil
end
