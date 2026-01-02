defmodule Streamix.Repo.Migrations.AddShowAdultContentToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :show_adult_content, :boolean, default: false, null: false
    end
  end
end
