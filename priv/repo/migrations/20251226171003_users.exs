defmodule Streamix.Repo.Migrations.Users do
  use Ecto.Migration

  def change do
    # Extensão para busca fuzzy (trigram)
    execute "CREATE EXTENSION IF NOT EXISTS pg_trgm", "DROP EXTENSION IF EXISTS pg_trgm"

    create table(:users) do
      add :email, :string, null: false, size: 160
      add :hashed_password, :string, null: false
      add :confirmed_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:users, [:email])
  end
end
