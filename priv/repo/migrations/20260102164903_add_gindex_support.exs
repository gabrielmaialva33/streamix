defmodule Streamix.Repo.Migrations.AddGindexSupport do
  use Ecto.Migration

  def change do
    # Add GIndex fields to provider
    alter table(:providers) do
      add :provider_type, :string, default: "xtream"
      add :gindex_url, :string
      add :gindex_drives, :map
    end

    # Add GIndex fields to movies
    alter table(:movies) do
      add :gindex_path, :string
      add :gindex_url_cached, :string
      add :gindex_url_expires_at, :utc_datetime
    end

    # Index for search by gindex_path
    create index(:movies, [:gindex_path])
    create index(:providers, [:provider_type])
  end
end
