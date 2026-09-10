defmodule Streamix.Embedplay.CatalogTest do
  use Streamix.DataCase, async: false
  use Oban.Testing, repo: Streamix.Repo

  alias Streamix.{Catalog, Embedplay, Providers, Repo}
  alias Streamix.Iptv.{CatalogItem, Movie}
  alias Streamix.Workers.TmdbDetailsWorker

  setup do
    original = Application.get_env(:streamix, :embedplay)
    request_options = Application.get_env(:streamix, :embedplay_catalog_request_options)
    Application.put_env(:streamix, :embedplay, enabled: true)

    Application.put_env(:streamix, :embedplay_catalog_request_options,
      plug: {Req.Test, __MODULE__}
    )

    on_exit(fn ->
      Application.put_env(:streamix, :embedplay, original || [])
      Application.put_env(:streamix, :embedplay_catalog_request_options, request_options || [])
    end)
  end

  test "single import is idempotent and preserves enriched metadata and catalog identity" do
    assert {:ok, id} = Embedplay.import_movie("603", "tt0133093")
    movie = Catalog.get_movie!(id)
    assert movie.stream_id == 603
    assert movie.tmdb_id == "603"
    assert movie.imdb_id == "tt0133093"
    assert movie.gindex_path == nil
    assert movie.gindex_url_cached == nil
    assert Repo.get!(CatalogItem, movie.catalog_item_id).source_group_id

    movie
    |> Ecto.Changeset.change(
      title: "Matrix",
      plot: "Enriched synopsis",
      track_metadata: %{"audio" => []},
      tmdb_details_at: ~U[2026-09-09 12:00:00Z]
    )
    |> Repo.update!()

    assert {:ok, ^id} = Embedplay.import_movie(603)
    updated = Catalog.get_movie!(id)
    assert updated.title == "Matrix"
    assert updated.plot == "Enriched synopsis"
    assert updated.track_metadata == %{"audio" => []}
    assert updated.imdb_id == "tt0133093"
    assert updated.catalog_item_id == movie.catalog_item_id
    assert updated.tmdb_details_at == ~U[2026-09-09 12:00:00Z]
    assert Providers.get_embedplay_provider().movies_count == 1
    assert Repo.aggregate(Movie, :count) == 1
    assert_enqueued(worker: TmdbDetailsWorker, args: %{kind: "movie", ids: [id]})
  end

  test "sync deduplicates identities, skips unsupported rows, and preserves missing films" do
    assert {:ok, retained_id} = Embedplay.import_movie(550, "tt0137523")

    Req.Test.stub(__MODULE__, fn conn ->
      Req.Test.json(conn, %{
        status: "success",
        results: %{
          movies: [
            %{tmdb_id: "603", imdb_id: "tt0133093"},
            %{tmdb_id: "603", imdb_id: "tt0133093"},
            %{imdb_id: "tt0000001"},
            %{tmdb_id: "invalid"}
          ]
        }
      })
    end)

    assert {:ok, %{imported: 1, skipped: 2}} = Embedplay.sync_catalog()
    assert {:ok, %{imported: 1, skipped: 2}} = Embedplay.sync_catalog()
    assert Catalog.get_movie!(retained_id)
    provider = Providers.get_embedplay_provider()
    assert provider.movies_count == 2
    assert provider.sync_status == "completed"
    assert provider.vod_synced_at
  end

  test "empty upstream leaves existing records intact" do
    assert {:ok, id} = Embedplay.import_movie(603)

    Req.Test.stub(__MODULE__, fn conn ->
      Req.Test.json(conn, %{status: "success", results: %{movies: []}})
    end)

    assert {:error, :empty_catalog} = Embedplay.sync_catalog()
    assert Catalog.get_movie!(id)
    assert Providers.get_embedplay_provider().movies_count == 1
  end

  test "disabled or inactive providers cannot import or enqueue a catalog sync" do
    Application.put_env(:streamix, :embedplay, enabled: false)
    assert {:ok, :disabled} = Providers.ensure_embedplay_provider()
    assert {:error, :embedplay_disabled} = Embedplay.import_movie(603)
    assert {:error, :embedplay_disabled} = Embedplay.enqueue_sync()
    assert {:error, :embedplay_disabled} = Embedplay.sync_catalog()

    Application.put_env(:streamix, :embedplay, enabled: true)
    {:ok, provider} = Providers.ensure_embedplay_provider()
    {:ok, _provider} = Providers.update_provider(provider, %{is_active: false})
    assert {:error, :provider_inactive} = Embedplay.import_movie(603)
  end

  test "ingestion rejects other provider types and does not accept ownership or URL fields" do
    import Streamix.IptvFixtures
    provider = global_provider_fixture()

    assert {:error, :not_embedplay_provider} =
             Catalog.upsert_embedplay_movie(provider.id, %{tmdb_id: 603})

    {:ok, embedplay} = Providers.ensure_embedplay_provider()

    assert {:ok, id} =
             Catalog.upsert_embedplay_movie(embedplay.id, %{
               tmdb_id: 603,
               provider_id: provider.id,
               catalog_item_id: -1,
               gindex_url_cached: "https://example.invalid/temporary"
             })

    movie = Catalog.get_movie!(id)
    assert movie.provider_id == embedplay.id
    assert movie.catalog_item_id != -1
    assert movie.gindex_url_cached == nil
  end
end
