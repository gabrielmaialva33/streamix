defmodule Streamix.Repo.Migrations.CreatePermissionTables do
  use Ecto.Migration

  def change do
    create table(:permissions) do
      add :name, :string, null: false
      add :description, :string

      timestamps(type: :utc_datetime)
    end

    create unique_index(:permissions, [:name])

    create table(:role_permissions) do
      add :role_id, references(:roles, on_delete: :delete_all), null: false
      add :permission_id, references(:permissions, on_delete: :delete_all), null: false
    end

    create unique_index(:role_permissions, [:role_id, :permission_id])

    create table(:user_permissions) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :permission_id, references(:permissions, on_delete: :delete_all), null: false
    end

    create unique_index(:user_permissions, [:user_id, :permission_id])
  end
end
