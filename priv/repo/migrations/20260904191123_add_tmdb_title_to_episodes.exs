defmodule Streamix.Repo.Migrations.AddTmdbTitleToEpisodes do
  use Ecto.Migration

  # TMDB's own episode name, kept in its own column rather than written into
  # `title`. Both sync paths list `title` in their replace set — the GIndex
  # ingest by name, the xtream one because the payload supplies it — so a
  # value written there survives only until the next scan.
  #
  # It is worth the column: 70.132 episodes carry no title at all and render as
  # "Episódio N", and 32.778 of those sit in seasons TMDB already answered for.
  # Another 2.091 carry a title that is only the series name plus a marker
  # ("A Caverna Encantada S01 E01"), which reads as a column of identical
  # truncated cards next to a badge that already says the number.
  def change do
    alter table(:episodes) do
      add :tmdb_title, :string
    end
  end
end
