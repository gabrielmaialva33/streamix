defmodule Streamix.Repo.Migrations.AddRoleToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :role, :string, null: false, default: "customer"
    end

    create index(:users, [:role])
  end
end
