defmodule Streamix.Repo.Migrations.LiveChannelCategories do
  use Ecto.Migration

  def change do
    create table(:live_channel_categories, primary_key: false) do
      add :live_channel_id, references(:live_channels, on_delete: :delete_all), null: false
      add :category_id, references(:categories, on_delete: :delete_all), null: false
    end

    create unique_index(:live_channel_categories, [:live_channel_id, :category_id])
    create index(:live_channel_categories, [:category_id])
  end
end
