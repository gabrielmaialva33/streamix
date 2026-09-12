defmodule Streamix.Iptv.Sync.TmdbStampRecoveryTest do
  use Streamix.DataCase, async: false

  import Streamix.IptvFixtures

  alias Ecto.Migration.Runner
  alias Streamix.Iptv.{Movie, Series}
  alias Streamix.Repo.Migrations.NormalizeInvalidXtreamMovieIds, as: NormalizeIds
  alias Streamix.Repo.Migrations.ResetInconsistentXtreamTmdbStamps, as: Repair

  unless Code.ensure_loaded?(Repair) do
    Code.require_file(
      Path.expand(
        "../../../../priv/repo/migrations/20260912000123_reset_inconsistent_xtream_tmdb_stamps.exs",
        __DIR__
      )
    )
  end

  unless Code.ensure_loaded?(NormalizeIds) do
    Code.require_file(
      Path.expand(
        "../../../../priv/repo/migrations/20260912012349_normalize_invalid_xtream_movie_ids.exs",
        __DIR__
      )
    )
  end

  test "identifier normalization affects only invalid Xtream movie IDs and preserves all other data" do
    stamped_at = DateTime.utc_now(:second)
    xtream = global_provider_fixture(%{provider_type: :xtream})
    torrent = global_provider_fixture(%{provider_type: :torrent})
    gindex = global_provider_fixture(%{provider_type: :gindex})

    cases = [
      {nil, nil, nil, nil},
      {"", "", nil, nil},
      {"0", "https://www.kinopoisk.ru/film/361/", nil, nil},
      {"550", "https://www.kinopoisk.ru/film/361/", "550", nil},
      {"0", "tt0137523", nil, "tt0137523"},
      {"550", "tt0137523", "550", "tt0137523"}
    ]

    rows =
      for provider <- [xtream, torrent, gindex],
          {tmdb_id, imdb_id, clean_tmdb, clean_imdb} <- cases do
        movie = movie_fixture(provider, %{plot: "Preserved plot"})

        Repo.update_all(from(m in Movie, where: m.id == ^movie.id),
          set: [
            tmdb_id: tmdb_id,
            imdb_id: imdb_id,
            tmdb_searched_at: stamped_at,
            tmdb_details_at: stamped_at,
            tmdb_miss_reason: "retained-reason"
          ]
        )

        before = Repo.get!(Movie, movie.id)

        expected =
          if provider.id == xtream.id,
            do: %{before | tmdb_id: clean_tmdb, imdb_id: clean_imdb},
            else: before

        {movie.id, expected}
      end

    for _pass <- 1..2 do
      Runner.run(Repo, Repo.config(), 20_260_912_012_349, NormalizeIds, :forward, :up, :up,
        log: false
      )

      for {id, expected} <- rows, do: assert(Repo.get!(Movie, id) == expected)
    end
  end

  test "repair clears only inconsistent Xtream/torrent stamps without recorded misses" do
    stamped_at = DateTime.utc_now(:second)
    xtream = global_provider_fixture(%{provider_type: :xtream})
    torrent = global_provider_fixture(%{provider_type: :torrent})
    gindex = global_provider_fixture(%{provider_type: :gindex})

    cases = [
      {nil, nil, nil, nil},
      {"", "", nil, nil},
      {"0", " ", nil, nil},
      {nil, "Valid plot", nil, stamped_at},
      {"550", "", stamped_at, nil},
      {"550", "Valid plot", stamped_at, stamped_at}
    ]

    rows =
      for schema <- [Movie, Series],
          provider <- [xtream, torrent, gindex],
          miss_reason <- [nil, "no_results", "low_score", ""],
          {tmdb_id, plot, search_stamp, details_stamp} <- cases do
        record = fixture(schema, provider)

        Repo.update_all(from(row in schema, where: row.id == ^record.id),
          set: [
            tmdb_id: tmdb_id,
            plot: plot,
            tmdb_searched_at: stamped_at,
            tmdb_details_at: stamped_at,
            tmdb_miss_reason: miss_reason
          ]
        )

        before = Repo.get!(schema, record.id)

        expected =
          if provider.id in [xtream.id, torrent.id] and is_nil(miss_reason) do
            %{before | tmdb_searched_at: search_stamp, tmdb_details_at: details_stamp}
          else
            before
          end

        {schema, record.id, expected}
      end

    for _pass <- 1..2 do
      # Execute the actual migration commands inside the SQL sandbox, without
      # changing schema_migrations or checking out a separate connection.
      Runner.run(
        Repo,
        Repo.config(),
        20_260_912_000_123,
        Repair,
        :forward,
        :up,
        :up,
        log: false
      )

      for {schema, id, expected} <- rows do
        assert Repo.get!(schema, id) == expected
      end
    end
  end

  defp fixture(Movie, provider), do: movie_fixture(provider)
  defp fixture(Series, provider), do: series_content_fixture(provider)
end
