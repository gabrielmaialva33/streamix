defmodule Streamix.Repo.Migrations.AddDeadSinceToVod do
  use Ecto.Migration
  @disable_ddl_transaction true
  @disable_migration_lock true

  def change do
    alter table(:movies) do
      add :dead_since, :utc_datetime
    end

    alter table(:episodes) do
      add :dead_since, :utc_datetime
    end

    create index(:movies, [:dead_since], where: "dead_since IS NOT NULL", concurrently: true)
    create index(:episodes, [:dead_since], where: "dead_since IS NOT NULL", concurrently: true)
  end
end
