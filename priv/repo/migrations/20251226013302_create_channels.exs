defmodule Streamix.Repo.Migrations.CreateChannels do
  use Ecto.Migration

  def change do
    create table(:channels) do
      add :name, :text, null: false
      add :logo_url, :text
      add :stream_url, :text, null: false
      add :tvg_id, :text
      add :tvg_name, :text
      add :group_title, :text
      add :provider_id, references(:providers, on_delete: :delete_all), null: false

      timestamps()
    end

    create index(:channels, [:provider_id])
  end
end
