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

  test "resumes from a durable folder checkpoint and preserves progress on quota", %{
    source: source
  } do
    parent = self()
    root_path = "/0:/Animes/"
    folders = Enum.map(~w(c a b), &%{name: String.upcase(&1), path: "/#{&1}/"})

    scrape_fun = fn _base_url, folder ->
      send(parent, {:scraped, folder.path})

      case folder.path do
        "/b/" -> {:ok, %{name: "B", episode_count: 2}}
        "/c/" -> {:error, {:quota_exhausted, 8_000}}
      end
    end

    persist_fun = fn _source, animes ->
      send(parent, {:persisted, Enum.map(animes, & &1.name)})
      {:ok, %{animes_count: length(animes), episodes_count: 2}}
    end

    assert {:error, {:quota_exhausted, 8_000}} =
             Animes.sync(source, "https://gindex.example", root_path,
               checkpoint: %{"root_path" => root_path, "folder_path" => "/a/"},
               batch_size: 1,
               list_fun: fn _base_url, ^root_path -> {:ok, folders} end,
               scrape_fun: scrape_fun,
               persist_fun: persist_fun,
               on_checkpoint: fn checkpoint ->
                 send(parent, {:checkpoint, checkpoint})
                 :ok
               end
             )

    refute_received {:scraped, "/a/"}
    assert_received {:scraped, "/b/"}
    assert_received {:persisted, ["B"]}
    assert_received {:checkpoint, %{"folder_path" => "/b/"}}
    assert_received {:scraped, "/c/"}
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
