defmodule Streamix.Iptv.TagsTest do
  use Streamix.DataCase, async: true

  import Streamix.IptvFixtures

  alias Streamix.Iptv.{Category, Tags}
  alias Streamix.Iptv.Tags.Vocabulary

  setup do
    %{provider: global_provider_fixture()}
  end

  describe "pending_documents/2" do
    test "one copy per title, only titles with something to read", %{provider: provider} do
      id = Integer.to_string(System.unique_integer([:positive]))
      first = movie_fixture(provider, %{title: "Com Sinopse", tmdb_id: id, plot: "Uma história."})
      {:ok, _} = Streamix.Catalog.apply_tmdb_metadata(:movies, id, %{keywords: [], credits: []})

      _copy =
        movie_fixture(global_provider_fixture(), %{title: "Com Sinopse", tmdb_id: id, plot: "x"})

      bare = movie_fixture(provider, %{title: "Sem Nada", plot: nil})

      keys = :movies |> Tags.pending_documents(1_000) |> Enum.map(& &1.variant_key)

      assert Enum.count(keys, &(&1 == "tmdb:" <> id)) == 1
      refute variant_key(bare) in keys

      assert [%{id: doc_id}] =
               Enum.filter(
                 Tags.pending_documents(:movies, 1_000),
                 &(&1.variant_key == "tmdb:" <> id)
               )

      assert doc_id == first.id
    end

    test "a TMDB title waits for its keywords and credits", %{provider: provider} do
      id = Integer.to_string(System.unique_integer([:positive]))
      movie_fixture(provider, %{title: "Aguardando", tmdb_id: id, plot: "x"})

      keys = fn -> :movies |> Tags.pending_documents(1_000) |> Enum.map(& &1.variant_key) end
      refute ("tmdb:" <> id) in keys.()

      {:ok, _} = Streamix.Catalog.apply_tmdb_metadata(:movies, id, %{keywords: [], credits: []})
      assert ("tmdb:" <> id) in keys.()
    end

    test "skips adult titles and titles already classified", %{provider: provider} do
      adult = movie_fixture(provider, %{title: "Adulto", plot: "x"})
      done = movie_fixture(provider, %{title: "Feito", plot: "x"})
      outdated = movie_fixture(provider, %{title: "Antigo", plot: "x"})

      category =
        %Category{}
        |> Category.changeset(%{
          provider_id: provider.id,
          name: "XXX",
          type: "vod",
          is_adult: true,
          external_id: Integer.to_string(System.unique_integer([:positive]))
        })
        |> Repo.insert!()

      Repo.insert_all("item_categories", [
        %{catalog_item_id: adult.catalog_item_id, category_id: category.id}
      ])

      {:ok, _} = Tags.put("movies", variant_key(done), %{moods: ["leve"]}, "test-model")
      {:ok, old} = Tags.put("movies", variant_key(outdated), %{}, "test-model")

      Repo.update_all(from(t in Streamix.Iptv.TitleTags, where: t.id == ^old.id),
        set: [vocabulary_version: 0]
      )

      keys = :movies |> Tags.pending_documents(1_000) |> Enum.map(& &1.variant_key)

      refute variant_key(adult) in keys
      refute variant_key(done) in keys
      assert variant_key(outdated) in keys
      assert Tags.pending_count(:movies) == length(keys)
    end
  end

  describe "put/5" do
    test "sanitizes, fixes the era, records model and version, and replaces" do
      key = "tmdb:#{System.unique_integer([:positive])}"

      assert {:ok, tags} =
               Tags.put(
                 "movies",
                 key,
                 %{
                   subgenres: ["slasher", "made-up"],
                   moods: ["tenso", "tenso"],
                   pace: "acelerado",
                   eras: ["atualidade"],
                   audience: ["adulto", "infantil"],
                   themes: nil
                 },
                 "gemini-test",
                 year: 1996
               )

      assert tags.subgenres == ["slasher"]
      assert tags.moods == ["tenso"]
      assert tags.pace == "acelerado"
      assert tags.eras == ["anos-1990"]
      assert tags.audience == "adulto"
      assert tags.themes == []
      assert tags.model == "gemini-test"
      assert tags.vocabulary_version == Vocabulary.version()

      assert {:ok, replaced} = Tags.put("movies", key, %{moods: ["leve"]}, "gemini-test")
      assert replaced.id == tags.id
      assert replaced.moods == ["leve"]
      assert replaced.subgenres == []

      assert %{^key => %{moods: ["leve"]}} = Tags.for_variants("movies", [key, nil])
      assert Tags.labels(replaced).moods == ["Leve"]
      assert Tags.labels(replaced).pace == []
      assert Tags.counts()["movies"] >= 1
    end
  end

  defp variant_key(movie) do
    Repo.one!(from(m in "movies", where: m.id == ^movie.id, select: m.variant_key))
  end
end
