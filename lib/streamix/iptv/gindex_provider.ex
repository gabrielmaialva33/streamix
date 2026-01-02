defmodule Streamix.Iptv.GIndexProvider do
  @moduledoc """
  Manages the GIndex provider configured via environment variables.

  The GIndex provider is used to index content from Google Drive Index servers.
  It is identified by `is_system: true`, `visibility: :global`, and `provider_type: :gindex`.
  """

  alias Streamix.Iptv.Provider
  alias Streamix.Repo

  import Ecto.Query

  require Logger

  @doc """
  Returns true if the GIndex provider is configured in the environment.
  """
  def enabled? do
    config()[:enabled] == true
  end

  @doc """
  Returns the GIndex provider configuration from the environment.
  """
  def config do
    Application.get_env(:streamix, :gindex_provider, enabled: false)
  end

  @doc """
  Returns the GIndex provider from the database, or nil if not found.
  """
  def get do
    Provider
    |> where(is_system: true, provider_type: :gindex)
    |> Repo.one()
  end

  @doc """
  Ensures the GIndex provider exists in the database.
  Creates it if it doesn't exist, updates it if URL changed.

  Returns {:ok, provider} or {:error, changeset}.
  """
  def ensure_exists! do
    if enabled?() do
      cfg = config()

      attrs = %{
        name: "GIndex",
        url: cfg[:url],
        gindex_url: cfg[:url],
        gindex_drives: %{
          "movies_path" => cfg[:movies_path] || "/1:/Filmes/"
        },
        provider_type: :gindex,
        is_system: true,
        visibility: :global,
        is_active: true
      }

      case get() do
        nil ->
          Logger.info("[GIndex] Creating GIndex provider...")
          create_provider(attrs)

        provider ->
          maybe_update_provider(provider, attrs)
      end
    else
      {:ok, :disabled}
    end
  end

  defp create_provider(attrs) do
    %Provider{}
    |> Provider.changeset(attrs)
    |> Repo.insert()
    |> tap(fn
      {:ok, provider} ->
        Logger.info("[GIndex] GIndex provider created with ID #{provider.id}")

      {:error, changeset} ->
        Logger.error("[GIndex] Failed to create GIndex provider: #{inspect(changeset.errors)}")
    end)
  end

  defp maybe_update_provider(provider, attrs) do
    if config_changed?(provider, attrs) do
      Logger.info("[GIndex] Updating GIndex provider configuration...")

      provider
      |> Provider.changeset(attrs)
      |> Repo.update()
    else
      {:ok, provider}
    end
  end

  @doc """
  Syncs the GIndex provider content (movies).
  """
  def sync! do
    case get() do
      nil ->
        {:error, :not_found}

      provider ->
        Streamix.Iptv.Gindex.Sync.sync_provider(provider)
    end
  end

  @doc """
  Returns the movies path for the GIndex provider.
  """
  def movies_path do
    case get() do
      nil -> config()[:movies_path] || "/1:/Filmes/"
      provider -> provider.gindex_drives["movies_path"] || "/1:/Filmes/"
    end
  end

  # Check if configuration changed
  defp config_changed?(provider, attrs) do
    provider.gindex_url != attrs[:gindex_url] ||
      provider.gindex_drives != attrs[:gindex_drives] ||
      provider.name != attrs[:name]
  end
end
