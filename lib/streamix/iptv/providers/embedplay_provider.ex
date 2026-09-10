defmodule Streamix.Iptv.EmbedplayProvider do
  @moduledoc false

  import Ecto.Query

  alias Streamix.Embedplay
  alias Streamix.Iptv.Provider
  alias Streamix.Repo

  def get do
    Repo.get_by(Provider, provider_type: :embedplay, is_system: true)
  end

  def ensure_exists do
    if Embedplay.enabled?() do
      case get() do
        nil -> create()
        provider -> {:ok, provider}
      end
    else
      {:ok, :disabled}
    end
  end

  defp create do
    attrs = %{
      name: "Embedplay",
      url: "https://embedplayapi.top",
      provider_type: :embedplay,
      is_system: true,
      visibility: :global,
      is_active: true
    }

    with {:ok, _provider} <-
           %Provider{}
           |> Provider.changeset(attrs)
           |> Repo.insert(on_conflict: :nothing) do
      {:ok, get()}
    end
  end

  def refresh_counts(provider_id, attrs) do
    case Repo.get_by(Provider, id: provider_id, provider_type: :embedplay) do
      nil ->
        {:error, :not_embedplay_provider}

      provider ->
        count =
          from(movie in Streamix.Iptv.Movie, where: movie.provider_id == ^provider_id)
          |> Repo.aggregate(:count)

        provider
        |> Provider.sync_changeset(Map.put(attrs, :movies_count, count))
        |> Repo.update()
    end
  end
end
