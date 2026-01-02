defmodule Streamix.Iptv.GlobalProvider do
  @moduledoc """
  Manages the global IPTV provider configured via environment variables.

  The global provider is visible to all users (including guests) and is
  identified by `is_system: true` and `visibility: :global`.
  """

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
    |> where(is_system: true, provider_type: :xtream)
    |> Repo.one()
  end

  @doc """
  Ensures the global provider exists in the database.
  Creates it if it doesn't exist, updates it if credentials changed.

  Returns {:ok, provider} or {:error, changeset}.
  """
  def ensure_exists! do
    if enabled?() do
      cfg = config()

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
        nil -> create_provider(attrs)
        provider -> maybe_update_provider(provider, attrs)
      end
    else
      {:ok, :disabled}
    end
  end

  defp create_provider(attrs) do
    %Provider{}
    |> Provider.changeset(attrs)
    |> Repo.insert()
  end

  defp maybe_update_provider(provider, attrs) do
    if credentials_changed?(provider, attrs) do
      provider
      |> Provider.changeset(attrs)
      |> Repo.update()
    else
      {:ok, provider}
    end
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
end
