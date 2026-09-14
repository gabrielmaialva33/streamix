defmodule Streamix.Iptv.Sync.GindexSeriesStampRecoveryTest do
  @moduledoc """
  958 GIndex series sit stamped as searched with no TMDB id and no recorded
  miss, which makes them unreachable: the matcher's pending query needs a null
  stamp, and the stale-miss requeue only revisits rows that carry a reason.

  The repair has to be narrow, because the two ways a row can legitimately look
  similar must survive it — a recorded miss (searched, genuinely no match) and
  a row belonging to any other provider type.
  """
  use Streamix.DataCase, async: false

  import Streamix.IptvFixtures

  alias Ecto.Migration.Runner
  alias Streamix.Iptv.Series
  alias Streamix.Repo.Migrations.ResetInconsistentGindexSeriesStamps, as: Repair

  unless Code.ensure_loaded?(Repair) do
    Code.require_file(
      Path.expand(
        "../../../../priv/repo/migrations/20260914150000_reset_inconsistent_gindex_series_stamps.exs",
        __DIR__
      )
    )
  end

  defp run_repair do
    Runner.run(Repo, Repo.config(), 20_260_914_150_000, Repair, :forward, :up, :up, log: false)
  end

  test "clears only GIndex series that are stamped with neither an id nor a reason" do
    stamped_at = DateTime.utc_now(:second)
    gindex = global_provider_fixture(%{provider_type: :gindex})
    xtream = global_provider_fixture(%{provider_type: :xtream})

    cases = [
      # {label, provider, attrs, stamp should be cleared?}
      {"gindex, nil id, no reason", gindex,
       %{tmdb_id: nil, tmdb_miss_reason: nil, tmdb_searched_at: stamped_at}, true},
      {"gindex, empty id, no reason", gindex,
       %{tmdb_id: "", tmdb_miss_reason: nil, tmdb_searched_at: stamped_at}, true},
      {"gindex, zero id, no reason", gindex,
       %{tmdb_id: "0", tmdb_miss_reason: nil, tmdb_searched_at: stamped_at}, true},
      {"gindex, recorded miss", gindex,
       %{tmdb_id: nil, tmdb_miss_reason: "tmdb:no_results", tmdb_searched_at: stamped_at}, false},
      {"gindex, matched", gindex,
       %{tmdb_id: "1399", tmdb_miss_reason: nil, tmdb_searched_at: stamped_at}, false},
      {"gindex, never searched", gindex,
       %{tmdb_id: nil, tmdb_miss_reason: nil, tmdb_searched_at: nil}, false},
      {"xtream, same shape", xtream,
       %{tmdb_id: nil, tmdb_miss_reason: nil, tmdb_searched_at: stamped_at}, false}
    ]

    rows =
      for {label, provider, attrs, cleared?} <- cases do
        series = series_content_fixture(provider, attrs)
        {label, series.id, cleared?, Repo.get!(Series, series.id)}
      end

    # Idempotent: a second pass must not widen the blast radius.
    for _pass <- 1..2 do
      run_repair()

      for {label, id, cleared?, before} <- rows do
        actual = Repo.get!(Series, id)
        expected = if cleared?, do: %{before | tmdb_searched_at: nil}, else: before

        assert actual == expected, """
        #{label}: repair #{if cleared?, do: "should", else: "should not"} have cleared the stamp.
        """
      end
    end
  end

  test "the repair touches no column other than the stamp" do
    gindex = global_provider_fixture(%{provider_type: :gindex})

    series =
      series_content_fixture(gindex, %{
        tmdb_id: nil,
        tmdb_miss_reason: nil,
        tmdb_searched_at: DateTime.utc_now(:second),
        plot: "sinopse preservada",
        name: "Nome preservado"
      })

    before = Repo.get!(Series, series.id)
    run_repair()
    actual = Repo.get!(Series, series.id)

    assert actual.tmdb_searched_at == nil
    assert actual == %{before | tmdb_searched_at: nil}
  end
end
