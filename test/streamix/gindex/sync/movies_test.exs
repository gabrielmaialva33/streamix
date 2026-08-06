defmodule Streamix.Gindex.Sync.MoviesTest do
  use Streamix.DataCase, async: true

  alias Streamix.Gindex.Sync.Movies
  alias Streamix.Iptv.{CatalogItem, Movie, Provider}
  alias Streamix.Repo

  @source %{provider_id: 42}
  @base_url "https://gindex.example"
  @root_path "/1:/Filmes/"
  @category_path "/1:/Filmes/2026/"
  @category %{name: "2026", path: @category_path}

  test "deduplicates repeated stream ids before creating catalog items and upserting" do
    provider = gindex_provider()
    movie = movie_data(42)

    assert {:ok, 1} = Movies.upsert_batch(%{provider_id: provider.id}, [movie, movie])

    assert Repo.aggregate(Movie, :count) == 1

    assert Repo.aggregate(
             from(c in CatalogItem, where: c.provider_id == ^provider.id),
             :count
           ) == 1
  end

  test "persists a partial category without falsely completing its cursor" do
    parent = self()
    items = [direct_movie("A"), direct_movie("B")]
    partial = {:partial_listing, %{items: items, items_collected: 2, page: 2}}

    assert {:error, {:partial_listing, returned_error}} =
             Movies.sync(@source, @base_url, @root_path,
               batch_size: 2,
               list_categories_fun: fn @base_url, @root_path -> {:ok, [@category]} end,
               list_items_fun: fn @base_url, @category_path -> {:error, partial} end,
               persist_fun: persist_fun(parent),
               on_checkpoint: checkpoint_fun(parent)
             )

    assert returned_error == %{items_collected: 2, page: 2}

    assert_received {:persisted, ["A", "B"]}

    assert_received {:checkpoint,
                     %{
                       "category_path" => @category_path,
                       "item_path" => "/1:/Filmes/2026/B.mkv",
                       "category_complete" => false,
                       "skipped_count" => 0
                     }}

    refute_received {:checkpoint, %{"category_complete" => true}}
  end

  test "resumes inside a formerly partial category and then completes it" do
    parent = self()

    checkpoint = %{
      "root_path" => @root_path,
      "category_path" => @category_path,
      "item_path" => "/1:/Filmes/2026/B.mkv",
      "category_complete" => false
    }

    assert {:ok, %{movies_count: 1, skipped_count: 0}} =
             Movies.sync(@source, @base_url, @root_path,
               checkpoint: checkpoint,
               list_categories_fun: fn @base_url, @root_path -> {:ok, [@category]} end,
               list_items_fun: fn @base_url, @category_path ->
                 {:ok, Enum.map(~w(A B C), &direct_movie/1)}
               end,
               persist_fun: persist_fun(parent),
               on_checkpoint: checkpoint_fun(parent)
             )

    assert_received {:persisted, ["C"]}
    refute_received {:persisted, ["A" | _]}
    assert_received {:checkpoint, %{"category_complete" => true, "item_path" => nil}}
  end

  test "carries skipped folders in the durable cursor and final stats" do
    parent = self()

    folder = %{
      type: :folder,
      name: "Broken",
      path: "/1:/Filmes/2026/Broken/"
    }

    assert {:ok, %{movies_count: 1, skipped_count: 1}} =
             Movies.sync(@source, @base_url, @root_path,
               batch_size: 1,
               list_categories_fun: fn @base_url, @root_path -> {:ok, [@category]} end,
               list_items_fun: fn @base_url, @category_path ->
                 {:ok, [folder, direct_movie("Working")]}
               end,
               scrape_folder_fun: fn @base_url, ^folder -> {:error, :upstream_unavailable} end,
               persist_fun: persist_fun(parent),
               on_checkpoint: checkpoint_fun(parent)
             )

    assert_received {:checkpoint, %{"skipped_count" => 1}}
    assert_received {:persisted, ["Working"]}
    assert_received {:checkpoint, %{"category_complete" => true, "skipped_count" => 1}}
  end

  defp gindex_provider do
    %Provider{}
    |> Provider.changeset(%{
      name: "GIndex Movie Sync Test",
      url: "https://gindex-movies.example.com",
      gindex_url: "https://gindex-movies.example.com",
      provider_type: :gindex,
      is_system: true,
      visibility: :global
    })
    |> Repo.insert!()
  end

  defp movie_data(stream_id) do
    %{
      stream_id: stream_id,
      name: "Duplicated Movie",
      title: "Duplicated Movie",
      year: 2026,
      container_extension: "mkv",
      gindex_path: "/1:/Filmes/2026/Duplicated Movie.mkv"
    }
  end

  defp direct_movie(name) do
    %{
      type: :file,
      name: "#{name}.mkv",
      path: "/1:/Filmes/2026/#{name}.mkv",
      size: 1_024
    }
  end

  defp persist_fun(parent) do
    fn _source, movies ->
      send(parent, {:persisted, Enum.map(movies, & &1.name)})
      {:ok, length(movies)}
    end
  end

  defp checkpoint_fun(parent) do
    fn checkpoint ->
      send(parent, {:checkpoint, checkpoint})
      :ok
    end
  end
end
