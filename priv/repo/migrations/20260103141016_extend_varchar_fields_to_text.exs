defmodule Streamix.Repo.Migrations.ExtendVarcharFieldsToText do
  use Ecto.Migration

  def change do
    # Movies - extend path and URL fields that can be very long
    alter table(:movies) do
      modify :gindex_path, :text, from: {:varchar, 255}
      modify :gindex_url_cached, :text, from: {:varchar, 255}
      modify :youtube_trailer, :text, from: {:varchar, 255}
      modify :tagline, :text, from: {:varchar, 255}
    end

    # Series - extend path field
    alter table(:series) do
      modify :gindex_path, :text, from: {:varchar, 255}
      modify :youtube_trailer, :text, from: {:varchar, 255}
      modify :tagline, :text, from: {:varchar, 255}
    end

    # Episodes - extend path and URL fields
    alter table(:episodes) do
      modify :gindex_path, :text, from: {:varchar, 255}
      modify :gindex_url_cached, :text, from: {:varchar, 255}
    end
  end
end
