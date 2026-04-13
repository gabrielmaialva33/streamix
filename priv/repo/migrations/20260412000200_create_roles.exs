defmodule Streamix.Repo.Migrations.CreateRoles do
  use Ecto.Migration

  def change do
    create table(:roles) do
      add :name, :string, null: false
      add :description, :string

      timestamps(type: :utc_datetime)
    end

    create unique_index(:roles, [:name])

    # Seed the three base roles
    execute(
      """
      INSERT INTO roles (name, description, inserted_at, updated_at) VALUES
        ('admin', 'Full system access', NOW(), NOW()),
        ('customer', 'Regular user', NOW(), NOW()),
        ('moderator', 'Content moderation', NOW(), NOW())
      """,
      "DELETE FROM roles WHERE name IN ('admin', 'customer', 'moderator')"
    )
  end
end
