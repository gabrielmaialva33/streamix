defmodule Streamix.Repo.Migrations.NormalizeInvalidXtreamMovieIds do
  use Ecto.Migration

  def up do
    # The preceding stamp repair already recognizes empty/zero TMDB IDs. Only
    # normalize invalid identifiers here; preserve every stamp and metadata field.
    execute("""
    UPDATE movies AS movie
    SET tmdb_id = CASE WHEN movie.tmdb_id IN ('', '0') THEN NULL ELSE movie.tmdb_id END,
        imdb_id = CASE WHEN movie.imdb_id NOT LIKE 'tt%' THEN NULL ELSE movie.imdb_id END
    FROM providers AS provider
    WHERE provider.id = movie.provider_id
      AND provider.provider_type = 'xtream'
      AND (movie.tmdb_id IN ('', '0') OR movie.imdb_id NOT LIKE 'tt%')
    """)
  end

  # Invalid identifiers have no useful inverse; do not reintroduce poisoned IDs.
  def down, do: :ok
end
