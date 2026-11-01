defmodule Streamix.Iptv.CatalogItemRedirect do
  @moduledoc """
  Records that a catalog item was replaced by another one.

  Favorites and watch history are sealed per user, so when a sync drops a
  duplicate catalog item the server cannot move anybody's history to the copy
  that stays. It leaves this redirect instead; the owner's next read
  (`Streamix.Iptv.History`, `Streamix.Iptv.Favorites`) re-seals the entry
  under the successor. The table names catalog items only, never users.

  Neither column has a foreign key: the replaced item is deleted right after,
  and the redirect has to outlive it. A successor that is replaced in turn
  gets its incoming redirects re-pointed, so chains stay one hop long.
  """
  use Ecto.Schema

  import Ecto.Query, warn: false

  alias Streamix.Repo

  @max_hops 5

  @primary_key {:catalog_item_id, :id, autogenerate: false}
  schema "catalog_item_redirects" do
    field :successor_id, :id

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @doc "Records `pairs` of `{replaced_catalog_item_id, successor_catalog_item_id}`."
  @spec record([{integer(), integer()}]) :: :ok
  def record([]), do: :ok

  def record(pairs) when is_list(pairs) do
    now = DateTime.utc_now(:second)
    pairs = for {from_id, to_id} <- pairs, from_id != to_id, do: {from_id, to_id}

    {:ok, _} =
      Repo.transact(fn ->
        for {from_id, to_id} <- pairs do
          from(redirect in __MODULE__, where: redirect.successor_id == ^from_id)
          |> Repo.update_all(set: [successor_id: to_id])
        end

        rows =
          for {from_id, to_id} <- pairs do
            %{catalog_item_id: from_id, successor_id: to_id, inserted_at: now}
          end

        Repo.insert_all(__MODULE__, rows,
          on_conflict: {:replace, [:successor_id, :inserted_at]},
          conflict_target: :catalog_item_id
        )

        {:ok, length(rows)}
      end)

    :ok
  end

  @doc """
  Maps each of `catalog_item_ids` that was replaced to its current successor,
  following chains of replacements.
  """
  @spec successors([integer()]) :: %{integer() => integer()}
  def successors([]), do: %{}

  def successors(catalog_item_ids) when is_list(catalog_item_ids) do
    resolve(Map.new(catalog_item_ids, &{&1, &1}), @max_hops)
  end

  defp resolve(current, 0), do: finished(current)

  defp resolve(current, hops) do
    next =
      from(redirect in __MODULE__,
        where: redirect.catalog_item_id in ^Enum.uniq(Map.values(current)),
        select: {redirect.catalog_item_id, redirect.successor_id}
      )
      |> Repo.all()
      |> Map.new()

    if next == %{} do
      finished(current)
    else
      current
      |> Map.new(fn {origin, at} -> {origin, Map.get(next, at, at)} end)
      |> resolve(hops - 1)
    end
  end

  defp finished(current) do
    for {origin, successor} <- current, origin != successor, into: %{}, do: {origin, successor}
  end
end
