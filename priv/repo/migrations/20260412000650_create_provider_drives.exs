defmodule Streamix.Repo.Migrations.CreateProviderDrives do
  use Ecto.Migration

  def change do
    create table(:provider_drives) do
      add :provider_id, references(:providers, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :drive_url, :string
      add :drive_type, :string
      add :metadata, :map, default: %{}

      timestamps(type: :utc_datetime)
    end

    create index(:provider_drives, [:provider_id])
  end
end
