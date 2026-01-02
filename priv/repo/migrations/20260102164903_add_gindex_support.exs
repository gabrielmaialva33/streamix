defmodule Streamix.Repo.Migrations.AddGindexSupport do
  use Ecto.Migration

  def change do
    # Adicionar campos de GIndex no provider
    alter table(:providers) do
      add :provider_type, :string, default: "xtream"
      add :gindex_url, :string
      add :gindex_drives, :map
    end

    # Adicionar campos de GIndex nos movies
    alter table(:movies) do
      add :gindex_path, :string
      add :gindex_url_cached, :string
      add :gindex_url_expires_at, :utc_datetime
    end

    # Índice para busca por gindex_path
    create index(:movies, [:gindex_path])
    create index(:providers, [:provider_type])
  end
end
