defmodule Streamix.Repo.Migrations.AddProviderVisibility do
  use Ecto.Migration

  def change do
    alter table(:providers) do
      add :visibility, :string, default: "private", null: false
      add :is_system, :boolean, default: false, null: false
    end

    # Permitir user_id nulo para provider global (is_system: true)
    execute "ALTER TABLE providers ALTER COLUMN user_id DROP NOT NULL",
            "ALTER TABLE providers ALTER COLUMN user_id SET NOT NULL"

    create index(:providers, [:visibility])
    create index(:providers, [:is_system])
  end
end
