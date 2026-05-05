defmodule Streamix.Iptv.GlobalProvider do
  @moduledoc """
  Manages the global IPTV provider configured via environment variables.

  The global provider is visible to all users (including guests) and is
  identified by `is_system: true` and `visibility: :global`.
  """

  alias Streamix.Accounts.User
  alias Streamix.Iptv.Provider
  alias Streamix.Repo

  import Ecto.Query

  @doc """
  Returns true if the global provider is configured in the environment.
  """
  def enabled? do
    config()[:enabled] == true
  end

  @doc """
  Returns the global provider configuration from the environment.
  """
  def config do
    Application.get_env(:streamix, :global_provider, enabled: false)
  end

  @doc """
  Returns the global provider from the database, or nil if not found.
  """
  def get do
    Provider
    |> where(is_system: true, visibility: :global, provider_type: :xtream)
    |> order_by(desc: :inserted_at, desc: :id)
    |> Repo.one()
  end

  @doc """
  Ensures the global provider exists in the database.
  Creates it if it doesn't exist, updates it if credentials changed.

  Returns {:ok, provider} or {:error, changeset}.
  """
  def ensure_exists!(owner \\ nil) do
    if enabled?() do
      cfg = config()
      owner_user_id = owner_user_id(owner)

      attrs = %{
        name: cfg[:name],
        url: cfg[:url],
        username: cfg[:username],
        password: cfg[:password],
        is_system: true,
        visibility: :global,
        is_active: true
      }

      case get() do
        nil -> create_provider(attrs, owner_user_id)
        provider -> maybe_update_provider(provider, attrs, owner_user_id)
      end
    else
      {:ok, :disabled}
    end
  end

  defp create_provider(attrs, owner_user_id) do
    %Provider{user_id: owner_user_id}
    |> Provider.changeset(attrs)
    |> Repo.insert()
  end

  defp maybe_update_provider(provider, attrs, owner_user_id) do
    if credentials_changed?(provider, attrs) or owner_changed?(provider, owner_user_id) do
      provider
      |> Provider.changeset(attrs)
      |> maybe_put_owner(owner_user_id)
      |> Repo.update()
    else
      {:ok, provider}
    end
  end

  defp maybe_put_owner(changeset, nil), do: changeset

  defp maybe_put_owner(changeset, owner_user_id) do
    Ecto.Changeset.put_change(changeset, :user_id, owner_user_id)
  end

  @doc """
  Syncs the global provider content (categories, channels, movies, series).
  """
  def sync! do
    case get() do
      nil ->
        {:error, :not_found}

      provider ->
        Streamix.Iptv.sync_provider(provider)
    end
  end

  # Check if credentials changed
  defp credentials_changed?(provider, attrs) do
    provider.url != attrs[:url] ||
      provider.username != attrs[:username] ||
      provider.password != attrs[:password] ||
      provider.name != attrs[:name]
  end

  defp owner_changed?(_provider, nil), do: false
  defp owner_changed?(provider, owner_user_id), do: provider.user_id != owner_user_id

  defp owner_user_id(%User{id: user_id}), do: user_id
  defp owner_user_id(user_id) when is_integer(user_id), do: user_id
  defp owner_user_id(_owner), do: nil
end
