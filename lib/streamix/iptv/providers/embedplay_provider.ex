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

  @doc """
  Marks the system Embedplay provider as degraded.

  Conditional on the current state, so concurrent callers agree on a single
  transition: only the caller that actually flipped the row gets the provider
  back, everyone else gets `:unchanged`. `is_active` is never touched.
  """
  @spec mark_degraded(atom() | String.t()) :: {:ok, Provider.t()} | :unchanged
  def mark_degraded(reason) when is_atom(reason) or is_binary(reason) do
    now = DateTime.utc_now(:second)

    transition(
      where(embedplay_query(), [p], p.health_status != :degraded),
      health_status: :degraded,
      degraded_at: now,
      degraded_reason: to_string(reason),
      updated_at: now
    )
  end

  @doc """
  Clears the degraded state of the system Embedplay provider.

  Returns the provider as it was while degraded, so the caller can report what
  it recovered from, or `:unchanged` when it was not degraded.
  """
  @spec mark_healthy() :: {:ok, Provider.t()} | :unchanged
  def mark_healthy do
    {:ok, result} =
      Repo.transact(fn ->
        degraded =
          embedplay_query()
          |> where([p], p.health_status == :degraded)
          |> lock("FOR UPDATE")
          |> Repo.one()

        if degraded do
          {1, _} =
            Repo.update_all(where(Provider, id: ^degraded.id),
              set: [
                health_status: :healthy,
                degraded_at: nil,
                degraded_reason: nil,
                updated_at: DateTime.utc_now(:second)
              ]
            )

          {:ok, {:ok, degraded}}
        else
          {:ok, :unchanged}
        end
      end)

    result
  end

  defp transition(query, changes) do
    case query |> select([p], p) |> Repo.update_all(set: changes) do
      {1, [provider]} -> {:ok, provider}
      {0, []} -> :unchanged
    end
  end

  defp embedplay_query do
    from(p in Provider, where: p.provider_type == :embedplay and p.is_system == true)
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
