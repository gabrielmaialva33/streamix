defmodule Streamix.Repo.Migrations.CreateExtensions do
  use Ecto.Migration

  def change do
    execute "CREATE EXTENSION IF NOT EXISTS pg_trgm", "DROP EXTENSION IF EXISTS pg_trgm"
    execute "CREATE EXTENSION IF NOT EXISTS citext", "DROP EXTENSION IF EXISTS citext"
    execute "CREATE EXTENSION IF NOT EXISTS unaccent", "SELECT 1"
  end
end
