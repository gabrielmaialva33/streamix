defmodule Streamix.Repo.Migrations.Favorites do
  use Ecto.Migration

  def change do
    create table(:favorites) do
      # "live_channel", "movie", "series"
      add :content_type, :string, null: false
      add :content_id, :integer, null: false
      add :content_name, :text
      add :content_icon, :text
      add :user_id, references(:users, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create index(:favorites, [:user_id])
    create index(:favorites, [:user_id, :content_type])
    create unique_index(:favorites, [:user_id, :content_type, :content_id])
  end
end
