defmodule Streamix.Iptv.Sync.Series.SeasonsEpisodesTest do
  @moduledoc """
  Regression for the "series with no episodes" bug.

  Some Xtream panels return the episodes grouped by season number in the
  `episodes` map while leaving the top-level `seasons` list empty. The
  sync used to build the season_number -> id map exclusively from the
  `seasons` list, so those episodes resolved to a nil season_id and were
  silently discarded (`upsert_episodes(_, nil, ...) -> 0`), leaving ~70%
  of the global provider's series unplayable.
  """

  use Streamix.DataCase, async: true

  import Streamix.AccountsFixtures
  import Streamix.IptvFixtures

  alias Streamix.Iptv.Episode
  alias Streamix.Iptv.Sync.Series.SeasonsEpisodes
  alias Streamix.Repo

  defp episode(id, num) do
    %{
      "id" => to_string(id),
      "episode_num" => to_string(num),
      "title" => "Episode #{num}",
      "container_extension" => "mp4"
    }
  end

  defp episodes_for_series(series_id) do
    Repo.one(
      from(e in Episode,
        join: s in "seasons",
        on: e.season_id == s.id,
        where: s.series_id == ^series_id,
        select: count()
      )
    )
  end

  setup do
    user = user_fixture()
    provider = provider_fixture(user)
    series = series_content_fixture(provider)
    %{series: series}
  end

  describe "sync/2 when the provider returns an empty seasons list" do
    test "still persists the episodes grouped under each season key", %{series: series} do
      info = %{
        "info" => %{},
        "seasons" => [],
        "episodes" => %{
          "1" => [episode(100, 1), episode(101, 2)],
          "2" => [episode(200, 1)]
        }
      }

      assert {:ok, %{seasons: seasons, episodes: episodes}} = SeasonsEpisodes.sync(series, info)
      assert episodes == 3
      assert seasons == 2
      assert episodes_for_series(series.id) == 3
    end
  end

  describe "sync/2 when the provider returns a populated seasons list" do
    test "keeps working (no regression)", %{series: series} do
      info = %{
        "info" => %{},
        "seasons" => [%{"season_number" => 1, "name" => "Season 1"}],
        "episodes" => %{"1" => [episode(100, 1), episode(101, 2)]}
      }

      assert {:ok, %{seasons: 1, episodes: 2}} = SeasonsEpisodes.sync(series, info)
      assert episodes_for_series(series.id) == 2
    end
  end
end
