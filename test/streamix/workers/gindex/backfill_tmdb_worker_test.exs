defmodule Streamix.Workers.Gindex.BackfillTmdbWorkerTest do
  use Streamix.DataCase, async: true

  import Streamix.IptvFixtures

  alias Streamix.Repo
  alias Streamix.Workers.Gindex.BackfillTmdbWorker

  test "formats structured miss reasons without invoking String.Chars" do
    assert BackfillTmdbWorker.format_miss_reason(:no_results) == "no_results"

    assert BackfillTmdbWorker.format_miss_reason({:http_error, 400}) ==
             "{:http_error, 400}"
  end

  describe "keep_artwork/2" do
    test "fills artwork in when the row has none" do
      attrs = %{tmdb_id: "550", stream_icon: "https://image.tmdb.org/p/w500/a.jpg"}

      assert %{stream_icon: "https://image.tmdb.org/p/w500/a.jpg"} =
               BackfillTmdbWorker.keep_artwork(attrs, nil)
    end

    test "never replaces artwork the row already carries" do
      attrs = %{tmdb_id: "550", stream_icon: "https://image.tmdb.org/p/w500/a.jpg"}
      kept = BackfillTmdbWorker.keep_artwork(attrs, "https://provider.example.com/poster.jpg")

      refute Map.has_key?(kept, :stream_icon)
      assert kept.tmdb_id == "550"
    end

    test "drops a blank incoming poster instead of blanking the column" do
      attrs = %{tmdb_id: "550", cover: nil}

      refute Map.has_key?(BackfillTmdbWorker.keep_artwork(attrs, nil), :cover)
      refute Map.has_key?(BackfillTmdbWorker.keep_artwork(%{cover: "  "}, nil), :cover)
    end

    test "treats an empty stored value as no artwork" do
      attrs = %{cover: "https://image.tmdb.org/p/w500/a.jpg"}

      assert %{cover: _} = BackfillTmdbWorker.keep_artwork(attrs, "")
    end
  end

  describe "cron selection" do
    setup do
      %{
        gindex: global_provider_fixture(%{provider_type: :gindex}),
        xtream: global_provider_fixture(%{provider_type: :xtream})
      }
    end

    test "sweeps rows that have no gindex_path", %{xtream: provider} do
      movie = movie_fixture(provider, %{name: "Rogue, o Assassino (2007)", gindex_path: nil})

      assert :ok = BackfillTmdbWorker.perform(%Oban.Job{args: %{}})
      assert movie.id in enqueued_ids("movie")
    end

    test "still sweeps gindex rows", %{gindex: provider} do
      movie = movie_fixture(provider, %{gindex_path: "/Filmes/Rogue (2007)/rogue.mkv"})

      assert :ok = BackfillTmdbWorker.perform(%Oban.Job{args: %{}})
      assert movie.id in enqueued_ids("movie")
    end

    test "skips adult titles TMDB will never carry", %{xtream: provider} do
      xxx = movie_fixture(provider, %{name: "[XXX] Oopsfamily 24 05 17 Amber Moore"})
      adulto = movie_fixture(provider, %{name: "Alguma Coisa [Adulto]"})
      prefixed = movie_fixture(provider, %{name: "XXX Hijabhookup Angeline"})
      normal = movie_fixture(provider, %{name: "Onde Começa o Inferno (1959)"})

      assert :ok = BackfillTmdbWorker.perform(%Oban.Job{args: %{}})

      ids = enqueued_ids("movie")
      assert normal.id in ids
      refute xxx.id in ids
      refute adulto.id in ids
      refute prefixed.id in ids
    end

    test "skips rows a previous pass already searched", %{xtream: provider} do
      searched =
        movie_fixture(provider, %{
          name: "Bosque Macabro (2014)",
          tmdb_searched_at: DateTime.utc_now(:second)
        })

      assert :ok = BackfillTmdbWorker.perform(%Oban.Job{args: %{}})
      refute searched.id in enqueued_ids("movie")
    end

    test "sweeps series the same way", %{xtream: provider} do
      series = series_content_fixture(provider, %{name: "Uma Série Qualquer (2019)"})

      assert :ok = BackfillTmdbWorker.perform(%Oban.Job{args: %{}})
      assert series.id in enqueued_ids("series")
    end
  end

  defp enqueued_ids(kind) do
    Oban.Job
    |> where([j], fragment("?->>'kind' = ?", j.args, ^kind))
    |> Repo.all()
    |> Enum.flat_map(& &1.args["ids"])
  end
end
