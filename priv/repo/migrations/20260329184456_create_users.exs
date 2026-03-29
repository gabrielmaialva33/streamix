defmodule Streamix.Repo.Migrations.CreateUsers do
  use Ecto.Migration

  def change do
    create table(:users) do
      add :email, :citext, null: false
      add :hashed_password, :string, null: false
      add :confirmed_at, :utc_datetime
      add :role, :string, null: false, default: "customer"
      add :show_adult_content, :boolean, null: false, default: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:users, [:email])
    create index(:users, [:role])

    execute(
      "ALTER TABLE users ADD CONSTRAINT users_role_check CHECK (role IN ('admin', 'customer', 'moderator'))",
      "ALTER TABLE users DROP CONSTRAINT IF EXISTS users_role_check"
    )
  end
end
