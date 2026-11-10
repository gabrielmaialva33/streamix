defmodule Streamix.Gindex.Sync.PersistenceTest do
  # Not async: one case reconfigures the global Logger level.
  use Streamix.DataCase, async: false

  import ExUnit.Callbacks, only: [on_exit: 1]
  import Streamix.AccountsFixtures, only: [user_fixture: 0, library_key_fixture: 1]

  alias Streamix.Gindex.Sync.Persistence
  alias Streamix.Iptv.{CatalogItem, CatalogItemRedirect, Episode, Provider, Season}
  alias Streamix.Iptv.Sync.Cleanup
  alias Streamix.Library
  alias Streamix.Repo
  alias Streamix.WatchParty.Room

  defp gindex_provider do
    %Provider{}
    |> Provider.changeset(%{
      name: "GIndex Persistence Test",
      url: "https://gindex.example/",
      gindex_url: "https://gindex.example/",
      provider_type: :gindex,
      is_system: true,
      visibility: :global
    })
    |> Repo.insert!()
  end

  # Builds the same series with an arbitrary set of episodes, so a season can be
  # replayed with different numbers for the same files.
  defp series_with(episodes), do: series_with_seasons([{1, episodes}])

  # The same across several seasons, as `[{season_number, [{episode_id,
  # episode_num}]}]`. A file's path, and so its episode_id, does not depend on
  # the season it is listed under: that is the production shape, where the
  # parser started filing an unchanged path under a different season.
  defp series_with_seasons(seasons) do
    %{
      series_id: 10_001,
      name: "Example Series",
      title: "Example Series",
      year: 2026,
      gindex_path: "/1:/Series/Example Series/",
      seasons:
        Enum.map(seasons, fn {season_number, episodes} ->
          %{
            season_number: season_number,
            name: "Season #{season_number}",
            episode_count: length(episodes),
            episodes:
              Enum.map(episodes, fn {episode_id, episode_num} ->
                %{
                  episode_id: episode_id,
                  episode_num: episode_num,
                  title: "Episode #{episode_num}",
                  name: "#{season_number}x#{pad(episode_num)} - Episode",
                  container_extension: "mkv",
                  gindex_path: "/1:/Series/Example/#{episode_id}.mkv"
                }
              end)
          }
        end)
    }
  end

  defp pad(number), do: String.pad_leading(to_string(number), 2, "0")

  defp sync(provider, data, now) do
    Persistence.upsert_series_content(%{provider_id: provider.id}, data, now)
  end

  defp episode_rows do
    Episode
    |> Repo.all()
    |> Enum.sort_by(& &1.episode_num)
    |> Enum.map(&{&1.episode_id, &1.episode_num})
  end

  defp season_rows do
    from(episode in Episode,
      join: season in assoc(episode, :season),
      order_by: [season.season_number, episode.episode_num],
      select: {season.season_number, episode.episode_id, episode.episode_num}
    )
    |> Repo.all()
  end

  defp rows_of(episode_id) do
    from(episode in Episode,
      join: season in assoc(episode, :season),
      where: episode.episode_id == ^episode_id,
      order_by: season.season_number,
      select: %{
        id: episode.id,
        season_number: season.season_number,
        episode_num: episode.episode_num,
        catalog_item_id: episode.catalog_item_id
      }
    )
    |> Repo.all()
  end

  defp with_info_log(fun) do
    previous = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: previous) end)

    ExUnit.CaptureLog.capture_log(fun)
  end

  defp series_data(episode_id, path) do
    %{
      series_id: 10_001,
      name: "Example Series",
      title: "Example Series",
      year: 2026,
      gindex_path: "/1:/Series/Example Series/",
      seasons: [
        %{
          season_number: 1,
          name: "Season 1",
          episode_count: 1,
          episodes: [
            %{
              episode_id: episode_id,
              episode_num: 1,
              title: "Pilot",
              name: "S01E01 - Pilot",
              container_extension: "mkv",
              gindex_path: path
            }
          ]
        }
      ]
    }
  end

  test "updates an episode whose path-derived id changed without violating episode_num" do
    provider = gindex_provider()
    now = ~U[2026-07-24 12:00:00Z]

    assert {:ok, 1} =
             Persistence.upsert_series_content(
               %{provider_id: provider.id},
               series_data(111, "/1:/Series/Example/S01/old.mkv"),
               now
             )

    original = Repo.one!(Episode)

    assert {:ok, 1} =
             Persistence.upsert_series_content(
               %{provider_id: provider.id},
               series_data(222, "/1:/Series/Example/S01/new.mkv"),
               DateTime.add(now, 60)
             )

    updated = Repo.one!(Episode)

    assert updated.id == original.id
    assert updated.catalog_item_id == original.catalog_item_id
    assert updated.episode_id == 222
    assert updated.episode_num == 1
    assert updated.gindex_path == "/1:/Series/Example/S01/new.mkv"

    assert Repo.aggregate(
             from(c in CatalogItem, where: c.content_type == "episode"),
             :count
           ) == 1
  end

  describe "episodes renumbered by a parser change" do
    # `episodes` has a unique index on (season_id, episode_num) and another on
    # (season_id, episode_id). Upserting only on the number treated a file whose
    # number changed as new, and the insert then collided with that file's own
    # row on the id index — in production the Postgrex unique_violation aborted
    # the batch and failed the scan root on every attempt.

    test "moves an existing file to its new number, keeping its row" do
      provider = gindex_provider()
      now = ~U[2026-07-24 12:00:00Z]

      assert {:ok, 1} = sync(provider, series_with([{111, 12}]), now)
      original = Repo.one!(Episode)

      assert {:ok, 1} = sync(provider, series_with([{111, 6}]), DateTime.add(now, 60))

      updated = Repo.one!(Episode)
      assert updated.id == original.id
      assert updated.catalog_item_id == original.catalog_item_id
      assert updated.episode_id == 111
      assert updated.episode_num == 6
    end

    test "fills a season that had collapsed onto a single number" do
      # The production shape: every file in the folder scored the same number,
      # `Enum.uniq_by/2` kept one, and the season was left holding one row.
      provider = gindex_provider()
      now = ~U[2026-07-24 12:00:00Z]

      assert {:ok, 1} = sync(provider, series_with([{111, 12}]), now)
      collapsed = Repo.one!(Episode)

      assert {:ok, 3} =
               sync(provider, series_with([{111, 6}, {222, 1}, {333, 2}]), DateTime.add(now, 60))

      assert episode_rows() == [{222, 1}, {333, 2}, {111, 6}]

      kept = Repo.get_by!(Episode, episode_id: 111)
      assert kept.id == collapsed.id
      assert kept.catalog_item_id == collapsed.catalog_item_id

      # The file that moved keeps its catalog item, so nothing else may be handed
      # the one it vacated — catalog_item_id is globally unique.
      catalog_item_ids = Episode |> Repo.all() |> Enum.map(& &1.catalog_item_id)
      assert length(Enum.uniq(catalog_item_ids)) == 3

      assert Repo.aggregate(from(c in CatalogItem, where: c.content_type == "episode"), :count) ==
               3
    end

    test "survives a season whose numbers merely permute" do
      # Without parking the rows first, Postgres checks the unique index row by
      # row and the swap collides with itself halfway through the statement.
      provider = gindex_provider()
      now = ~U[2026-07-24 12:00:00Z]

      assert {:ok, 2} = sync(provider, series_with([{111, 1}, {222, 2}]), now)
      before = Map.new(Repo.all(Episode), &{&1.episode_id, &1.id})

      assert {:ok, 2} = sync(provider, series_with([{111, 2}, {222, 1}]), DateTime.add(now, 60))

      assert episode_rows() == [{222, 1}, {111, 2}]

      after_swap = Map.new(Repo.all(Episode), &{&1.episode_id, &1.id})
      assert after_swap == before
    end

    test "leaves no parked negative numbers behind" do
      provider = gindex_provider()
      now = ~U[2026-07-24 12:00:00Z]

      assert {:ok, 2} = sync(provider, series_with([{111, 8}, {222, 9}]), now)
      assert {:ok, 2} = sync(provider, series_with([{111, 1}, {222, 2}]), DateTime.add(now, 60))

      assert Repo.aggregate(from(e in Episode, where: e.episode_num < 0), :count) == 0
    end
  end

  describe "a number reassigned from a file that is gone" do
    # The collision neither conflict target can resolve: a file that is still
    # in the listing moves onto a number held by a row whose own file is not.
    # Because the mover upserts on episode_id, the row in its way is never
    # visited and Postgres rejects the batch on (season_id, episode_num). In
    # production this left /0:/Animes/ `failed` and
    # /1:/Séries/Séries Misturado/ retrying for eleven days.

    test "drops the stale row and lets the surviving file take the number" do
      provider = gindex_provider()
      now = ~U[2026-10-12 12:00:00Z]

      # The production shape, from /0:/Animes/Digimon Savers/: one file parsed
      # as 0 by the old digit-run fallback, another already holding 1.
      assert {:ok, 2} = sync(provider, series_with([{111, 0}, {222, 1}]), now)

      kept = Repo.get_by!(Episode, episode_id: 111)
      gone = Repo.get_by!(Episode, episode_id: 222)

      # Only the first file is still upstream, and it now parses as 1.
      assert {:ok, 1} = sync(provider, series_with([{111, 1}]), DateTime.add(now, 60))

      assert episode_rows() == [{111, 1}]

      moved = Repo.get_by!(Episode, episode_id: 111)
      assert moved.id == kept.id
      assert moved.catalog_item_id == kept.catalog_item_id
      refute Repo.get(Episode, gone.id)
    end

    test "still repurposes the row when a new file claims the number" do
      # Unchanged behaviour: when the claimant is a file the season has never
      # seen, (season_id, episode_num) is the conflict target and the row is
      # reused rather than dropped, so its catalog item survives.
      provider = gindex_provider()
      now = ~U[2026-10-12 12:00:00Z]

      assert {:ok, 1} = sync(provider, series_with([{111, 1}]), now)
      original = Repo.one!(Episode)

      assert {:ok, 1} = sync(provider, series_with([{999, 1}]), DateTime.add(now, 60))

      reused = Repo.one!(Episode)
      assert reused.id == original.id
      assert reused.catalog_item_id == original.catalog_item_id
      assert reused.episode_id == 999
    end

    @tag :capture_log
    test "says which files it drops when two share a number" do
      provider = gindex_provider()
      now = ~U[2026-10-12 12:00:00Z]

      # The suite runs the Logger at :warning, and this is reported at :info
      # precisely because it is an ordinary event rather than a fault.
      previous = Logger.level()
      Logger.configure(level: :info)
      on_exit(fn -> Logger.configure(level: previous) end)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, 1} = sync(provider, series_with([{111, 7}, {222, 7}]), now)
        end)

      # Silence here is how the catalogue lost episodes without a trace.
      assert log =~ "collide on an episode number"
      assert episode_rows() == [{111, 7}]
    end

    test "counts a file listed twice as one drop, not zero" do
      # Production logged "season 42784: 0 file(s) collide ... were dropped"
      # when the listing carried the same file twice: filtering out every
      # episode_id that survived also removed the copy that had been dropped.
      provider = gindex_provider()
      now = ~U[2026-10-12 12:00:00Z]

      previous = Logger.level()
      Logger.configure(level: :info)
      on_exit(fn -> Logger.configure(level: previous) end)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, 1} = sync(provider, series_with([{111, 3}, {111, 3}]), now)
        end)

      assert log =~ "1 file(s) collide"
      refute log =~ "0 file(s) collide"
      assert episode_rows() == [{111, 3}]
    end
  end

  describe "a file whose season changed between scans" do
    # 209f6a7a made the parser report the season `SxxEyy` names, and each
    # per-season upsert only sees its own season, so a file filed under the
    # wrong one got a second row in the right one. In production, series Vida:
    #
    #     season 1  ep 7  Vida-S02E07 - Episódio 7.mkv  created 2026-09-20
    #     season 2  ep 7  Vida-S02E07 - Episódio 7.mkv  created 2026-10-12
    #
    # The new row starts with no history; the old one stays as a duplicate.

    test "moves its row to the season the listing names, history included" do
      provider = gindex_provider()
      user = user_fixture()
      now = ~U[2026-09-20 12:00:00Z]

      # The Vida shape: the S02E07 file was filed as season 1, episode 7.
      assert {:ok, 2} = sync(provider, series_with_seasons([{1, [{101, 1}, {207, 7}]}]), now)
      [misfiled] = rows_of(207)
      key = library_key_fixture(user)
      watch!(key, misfiled)

      assert {:ok, 2} =
               sync(
                 provider,
                 series_with_seasons([{1, [{101, 1}]}, {2, [{207, 7}]}]),
                 ~U[2026-10-12 12:00:00Z]
               )

      assert [%{season_number: 2, episode_num: 7} = moved] = rows_of(207)
      assert moved.id == misfiled.id
      assert moved.catalog_item_id == misfiled.catalog_item_id
      assert season_rows() == [{1, 101, 1}, {2, 207, 7}]

      # The progress now sits on the row the season-2 listing points at, and
      # the orphan sweep has nothing to take.
      assert {:ok, %{catalog_items: 0}} = Cleanup.cleanup_orphaned_user_data()
      assert history_of(key) == [moved.id]
    end

    test "lands on numbers held by a renumbered file and by a file that is gone" do
      provider = gindex_provider()
      now = ~U[2026-10-12 12:00:00Z]

      # 111 and 555 are about to move to season 2, onto 7 and 8. 333 holds 7
      # there and is renumbered to 9; 444 holds 8 and is gone from the listing.
      assert {:ok, 5} =
               sync(
                 provider,
                 series_with_seasons([
                   {1, [{101, 1}, {111, 7}, {555, 8}]},
                   {2, [{333, 7}, {444, 8}]}
                 ]),
                 now
               )

      before = Map.new(Repo.all(Episode), &{&1.episode_id, {&1.id, &1.catalog_item_id}})

      assert {:ok, 4} =
               sync(
                 provider,
                 series_with_seasons([
                   {1, [{101, 1}]},
                   {2, [{111, 7}, {555, 8}, {333, 9}]}
                 ]),
                 DateTime.add(now, 60)
               )

      assert season_rows() == [{1, 101, 1}, {2, 111, 7}, {2, 555, 8}, {2, 333, 9}]

      after_move = Map.new(Repo.all(Episode), &{&1.episode_id, {&1.id, &1.catalog_item_id}})
      assert after_move == Map.delete(before, 444)
    end

    test "follows a release slot shift without trading catalog items between files" do
      # Anime seasons are release slots numbered by folder order, so a release
      # folder sorting first pushes every other release up one slot. Matching
      # by number alone handed each file the history of whatever sat in its
      # new slot before.
      provider = gindex_provider()
      now = ~U[2026-10-12 12:00:00Z]

      assert {:ok, 4} =
               sync(
                 provider,
                 series_with_seasons([{1, [{111, 1}, {112, 2}]}, {2, [{211, 1}, {212, 2}]}]),
                 now
               )

      before = Map.new(Repo.all(Episode), &{&1.episode_id, {&1.id, &1.catalog_item_id}})

      assert {:ok, 6} =
               sync(
                 provider,
                 series_with_seasons([
                   {1, [{311, 1}, {312, 2}]},
                   {2, [{111, 1}, {112, 2}]},
                   {3, [{211, 1}, {212, 2}]}
                 ]),
                 DateTime.add(now, 60)
               )

      assert season_rows() == [
               {1, 311, 1},
               {1, 312, 2},
               {2, 111, 1},
               {2, 112, 2},
               {3, 211, 1},
               {3, 212, 2}
             ]

      after_shift = Map.new(Repo.all(Episode), &{&1.episode_id, {&1.id, &1.catalog_item_id}})
      assert Map.take(after_shift, Map.keys(before)) == before
      assert Repo.aggregate(from(e in Episode, where: e.episode_num < 0), :count) == 0
    end

    test "leaves a file listed under two seasons alone while another file moves" do
      provider = gindex_provider()
      now = ~U[2026-10-12 12:00:00Z]

      # 777 is listed under both seasons of the same scrape; 888 moves.
      assert {:ok, 4} =
               sync(
                 provider,
                 series_with_seasons([{1, [{101, 1}, {888, 5}, {777, 9}]}, {2, [{777, 9}]}]),
                 now
               )

      both_slots = rows_of(777)
      [mover] = rows_of(888)
      assert length(both_slots) == 2

      assert {:ok, 4} =
               sync(
                 provider,
                 series_with_seasons([{1, [{101, 1}, {777, 9}]}, {2, [{777, 9}, {888, 5}]}]),
                 DateTime.add(now, 60)
               )

      assert rows_of(777) == both_slots
      assert [%{season_number: 2, episode_num: 5, id: id}] = rows_of(888)
      assert id == mover.id
    end

    test "drops a legacy duplicate that carries no user data" do
      provider = gindex_provider()
      now = ~U[2026-10-12 12:00:00Z]

      # What the previous code left behind: the file in both seasons. A scrape
      # listing it under both is the simplest way to build that state now.
      assert {:ok, 3} =
               sync(
                 provider,
                 series_with_seasons([{1, [{101, 1}, {207, 7}]}, {2, [{207, 7}]}]),
                 now
               )

      [ghost, correct] = rows_of(207)
      assert ghost.season_number == 1

      assert {:ok, 2} =
               sync(
                 provider,
                 series_with_seasons([{1, [{101, 1}]}, {2, [{207, 7}]}]),
                 DateTime.add(now, 60)
               )

      assert rows_of(207) == [correct]
      refute Repo.get(Episode, ghost.id)
      assert season_rows() == [{1, 101, 1}, {2, 207, 7}]
    end

    # The server cannot see whose history hangs off a ghost: it is sealed per
    # user. The ghost goes, and a redirect lets each owner's next read move
    # their entry to the row that stays.
    test "drops a legacy duplicate that carries user data, and its owner's history follows" do
      provider = gindex_provider()
      user = user_fixture()
      now = ~U[2026-10-12 12:00:00Z]

      assert {:ok, 3} =
               sync(
                 provider,
                 series_with_seasons([{1, [{101, 1}, {207, 7}]}, {2, [{207, 7}]}]),
                 now
               )

      [ghost, correct] = rows_of(207)
      key = library_key_fixture(user)
      watch!(key, ghost)
      assert {:ok, _favorite} = Library.add_favorite(key, "episode", ghost.id)

      assert {:ok, 2} =
               sync(
                 provider,
                 series_with_seasons([{1, [{101, 1}]}, {2, [{207, 7}]}]),
                 DateTime.add(now, 60)
               )

      assert rows_of(207) == [correct]
      refute Repo.get(Episode, ghost.id)

      assert CatalogItemRedirect.successors([ghost.catalog_item_id]) == %{
               ghost.catalog_item_id => correct.catalog_item_id
             }

      assert {:ok, %{catalog_items: 1}} = Cleanup.cleanup_orphaned_user_data()

      assert history_of(key) == [correct.id]
      assert [%{content_type: "episode", content_id: favorite_id}] = Library.list_favorites(key)
      assert favorite_id == correct.id
    end

    test "keeps a legacy duplicate a watch-party room points at, and says so" do
      provider = gindex_provider()
      user = user_fixture()
      now = ~U[2026-10-12 12:00:00Z]

      assert {:ok, 3} =
               sync(
                 provider,
                 series_with_seasons([{1, [{101, 1}, {207, 7}]}, {2, [{207, 7}]}]),
                 now
               )

      [ghost, correct] = rows_of(207)

      %Room{}
      |> Room.create_changeset(%{
        host_user_id: user.id,
        catalog_item_id: ghost.catalog_item_id,
        source_type: "episode",
        source_id: ghost.id
      })
      |> Repo.insert!()

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, 2} =
                   sync(
                     provider,
                     series_with_seasons([{1, [{101, 1}]}, {2, [{207, 7}]}]),
                     DateTime.add(now, 60)
                   )
        end)

      assert rows_of(207) == [ghost, correct]
      assert log =~ "[warning]"
      assert log =~ "/1:/Series/Example/207.mkv"
      assert log =~ "listed only in season 2"
      assert log =~ "older row in season 1 has a watch-party room"
      assert CatalogItemRedirect.successors([ghost.catalog_item_id]) == %{}
    end

    test "moves the oldest copy when the listed season has none, and history follows" do
      provider = gindex_provider()
      user = user_fixture()
      now = ~U[2026-10-12 12:00:00Z]

      assert {:ok, 2} =
               sync(provider, series_with_seasons([{1, [{207, 7}]}, {3, [{207, 7}]}]), now)

      [oldest, watched] = rows_of(207)
      assert watched.season_number == 3
      key = library_key_fixture(user)
      watch!(key, watched)

      assert {:ok, 3} =
               sync(
                 provider,
                 series_with_seasons([{1, [{101, 1}]}, {2, [{207, 7}]}, {3, [{301, 1}]}]),
                 DateTime.add(now, 60)
               )

      assert [%{season_number: 2, episode_num: 7} = moved] = rows_of(207)
      assert moved.id == oldest.id
      refute Repo.get(Episode, watched.id)

      assert {:ok, _counts} = Cleanup.cleanup_orphaned_user_data()
      assert history_of(key) == [moved.id]
    end

    @tag :capture_log
    test "moves nothing when the series fails partway, and completes on the next scan" do
      provider = gindex_provider()
      now = ~U[2026-10-12 12:00:00Z]

      assert {:ok, 2} = sync(provider, series_with_seasons([{1, [{101, 1}, {207, 7}]}]), now)
      [misfiled] = rows_of(207)
      catalog_items = Repo.aggregate(CatalogItem, :count)

      # Season 3 is written last, after 207 has been moved into season 2 and
      # unparked there; its NULL episode number then aborts the statement.
      broken =
        update_in(
          series_with_seasons([{1, [{101, 1}]}, {2, [{207, 7}]}, {3, [{301, 1}]}]),
          [:seasons, Access.at(2), :episodes, Access.at(0), :episode_num],
          fn _ -> nil end
        )

      assert {:error, %Postgrex.Error{postgres: %{code: :not_null_violation}}} =
               sync(provider, broken, DateTime.add(now, 60))

      assert rows_of(207) == [misfiled]
      assert season_rows() == [{1, 101, 1}, {1, 207, 7}]
      assert Repo.aggregate(Season, :count) == 1
      assert Repo.aggregate(CatalogItem, :count) == catalog_items

      assert {:ok, 2} =
               sync(
                 provider,
                 series_with_seasons([{1, [{101, 1}]}, {2, [{207, 7}]}]),
                 DateTime.add(now, 120)
               )

      assert [%{season_number: 2, id: id}] = rows_of(207)
      assert id == misfiled.id
    end
  end

  describe "a file listed twice in one season" do
    @tag :capture_log
    test "keeps one row when the copies parse to different numbers" do
      # Deduping by number alone kept both, and the insert then broke the
      # unique index on (season_id, episode_id) and aborted the series.
      provider = gindex_provider()

      log =
        with_info_log(fn ->
          assert {:ok, 1} =
                   sync(provider, series_with([{111, 3}, {111, 4}]), ~U[2026-10-12 12:00:00Z])
        end)

      assert episode_rows() == [{111, 3}]
      assert log =~ "1 file(s) collide"
      assert log =~ "4=1x04 - Episode (same file)"
    end
  end

  defp watch!(key, episode_row) do
    assert {:ok, _entry} =
             Library.add_watch_history(key, "episode", episode_row.id, %{progress_seconds: 600})
  end

  # Episode ids in the user's history, as their own read resolves them.
  defp history_of(key) do
    key
    |> Library.list_watch_history()
    |> Enum.map(& &1.content_id)
  end

  test "rolls back the catalog item when the series cannot be inserted" do
    provider = gindex_provider()
    invalid_data = %{series_data(111, "/1:/Series/Example/S01/pilot.mkv") | name: nil}

    assert {:error, %Ecto.InvalidChangesetError{}} =
             Persistence.upsert_series_content(
               %{provider_id: provider.id},
               invalid_data,
               ~U[2026-07-24 12:00:00Z]
             )

    assert Repo.aggregate(CatalogItem, :count) == 0
  end
end
