defmodule Streamix.Repo.Migrations.AddTrackMetadataToMoviesEpisodes do
  use Ecto.Migration

  @moduledoc """
  Adds `track_metadata` jsonb to movies and episodes. Populated lazily
  by the GIndex track endpoint; Choki content never touches this column
  (hls.js/mpegts.js enumerate tracks at runtime).
  """

  def change do
    alter table(:movies) do
      add :track_metadata, :jsonb
    end

    alter table(:episodes) do
      add :track_metadata, :jsonb
    end
  end
end
