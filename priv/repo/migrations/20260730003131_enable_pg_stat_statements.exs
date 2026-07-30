defmodule Streamix.Repo.Migrations.EnablePgStatStatements do
  use Ecto.Migration

  def up do
    execute("CREATE EXTENSION IF NOT EXISTS pg_stat_statements")
  end

  # migration-safety: reviewed — rollback only removes the optional statistics
  # extension and its collected samples; it never touches application data.
  def down do
    execute("DROP EXTENSION IF EXISTS pg_stat_statements")
  end
end
