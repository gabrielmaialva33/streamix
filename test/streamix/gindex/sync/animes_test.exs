defmodule Streamix.Gindex.Sync.AnimesTest do
  use Streamix.DataCase, async: true

  alias Streamix.Gindex.Sync.Animes
  alias Streamix.Iptv.{CatalogItem, Series}

  import Streamix.IptvFixtures

  setup do
    provider = global_provider_fixture(%{provider_type: :gindex})
    %{source: %{provider_id: provider.id}}
  end

  test "counts only durably persisted anime rows", %{source: source} do
    anime = anime_data(%{series_id: 101, name: "Cowboy Example"})

    assert {:ok, %{animes_count: 1, episodes_count: 0}} =
             Animes.upsert_batch(source, [anime])

    assert Repo.aggregate(Series, :count) == 1
  end

  test "propagates persistence failures instead of reporting partial success", %{source: source} do
    invalid_anime = anime_data(%{series_id: 102, name: nil})

    assert {:error, %Ecto.InvalidChangesetError{}} =
             Animes.upsert_batch(source, [invalid_anime])

    assert Repo.aggregate(Series, :count) == 0
    assert Repo.aggregate(CatalogItem, :count) == 0
  end

  defp anime_data(attrs) do
    Enum.into(attrs, %{
      title: Map.get(attrs, :name),
      year: 2026,
      gindex_path: "/0:/Animes/example/",
      seasons: []
    })
  end
end
