defmodule Streamix.Repo.Migrations.CreateFavorites do
  use Ecto.Migration

  def change do
    create table(:favorites) do
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

    execute(
      "ALTER TABLE favorites ADD CONSTRAINT favorites_content_type_check CHECK (content_type IN ('live_channel', 'movie', 'series'))",
      "ALTER TABLE favorites DROP CONSTRAINT IF EXISTS favorites_content_type_check"
    )
  end
end
