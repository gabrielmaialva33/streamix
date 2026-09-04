defmodule Streamix.Workers.EpisodeDetailsWorkerTest do
  use Streamix.DataCase, async: false

  import Streamix.IptvFixtures

  alias Streamix.Iptv.{Episode, Season}
  alias Streamix.Repo
  alias Streamix.Workers.EpisodeDetailsWorker

  setup do
    previous = Application.get_env(:streamix, :tmdb)
    Application.put_env(:streamix, :tmdb, enabled: false)

    on_exit(fn ->
      if previous do
        Application.put_env(:streamix, :tmdb, previous)
      else
        Application.delete_env(:streamix, :tmdb)
      end
    end)

    %{provider: global_provider_fixture(%{provider_type: :gindex})}
  end

  describe "enqueue_pending/1" do
    test "takes seasons of a series that carries a tmdb_id", %{provider: provider} do
      matched = season_for(provider, tmdb_id: "1399")
      _unmatched = season_for(provider, tmdb_id: nil)

      assert %{seasons: 1, batches: 1} = EpisodeDetailsWorker.enqueue_pending()
      assert enqueued_season_ids() == [matched.id]
    end

    test "skips a season that was already read", %{provider: provider} do
      season = season_for(provider, tmdb_id: "1399")
      stamp(season)

      assert %{seasons: 0, batches: 0} = EpisodeDetailsWorker.enqueue_pending()
      assert enqueued_season_ids() == []
    end

    test "spreads batches over time", %{provider: provider} do
      for _ <- 1..5, do: season_for(provider, tmdb_id: "1399")

      assert %{batches: 3} = EpisodeDetailsWorker.enqueue_pending(batch_size: 2, delay: 30)
      assert length(Enum.uniq(Enum.map(jobs(), & &1.scheduled_at))) == 3
    end
  end

  describe "perform/1 batch mode" do
    test "stamps the season even when TMDB has nothing", %{provider: provider} do
      season = season_for(provider, tmdb_id: "1399")

      assert :ok =
               EpisodeDetailsWorker.perform(%Oban.Job{args: %{"season_ids" => [season.id]}})

      assert %Season{tmdb_details_at: %DateTime{}} = Repo.get!(Season, season.id)

      # The stamp is the point: a second pass must not queue it again.
      assert %{seasons: 0} = EpisodeDetailsWorker.enqueue_pending()
    end

    test "ignores a season whose series lost its tmdb_id", %{provider: provider} do
      season = season_for(provider, tmdb_id: nil)

      assert :ok =
               EpisodeDetailsWorker.perform(%Oban.Job{args: %{"season_ids" => [season.id]}})

      assert %Season{tmdb_details_at: nil} = Repo.get!(Season, season.id)
    end

    test "tolerates a season id that no longer exists", %{provider: provider} do
      season = season_for(provider, tmdb_id: "1399")
      Repo.delete_all(from(e in Episode, where: e.season_id == ^season.id))
      Repo.delete!(season)

      assert :ok =
               EpisodeDetailsWorker.perform(%Oban.Job{args: %{"season_ids" => [season.id]}})
    end
  end

  test "uses a bounded timeout below the Lifeline threshold" do
    assert EpisodeDetailsWorker.timeout(%Oban.Job{}) == :timer.minutes(15)
  end

  defp season_for(provider, tmdb_id: tmdb_id) do
    series = series_content_fixture(provider, %{tmdb_id: tmdb_id})
    season = Repo.insert!(%Season{series_id: series.id, season_number: 1, episode_count: 1})
    catalog_item = catalog_item_fixture("episode", provider.id)

    Repo.insert!(%Episode{
      season_id: season.id,
      catalog_item_id: catalog_item.id,
      episode_id: System.unique_integer([:positive]),
      episode_num: 1
    })

    season
  end

  defp stamp(season) do
    Repo.update_all(from(s in Season, where: s.id == ^season.id),
      set: [tmdb_details_at: DateTime.utc_now(:second)]
    )
  end

  defp jobs do
    Repo.all(from(j in Oban.Job, where: j.worker == "Streamix.Workers.EpisodeDetailsWorker"))
  end

  defp enqueued_season_ids do
    jobs() |> Enum.flat_map(& &1.args["season_ids"]) |> Enum.sort()
  end
end
