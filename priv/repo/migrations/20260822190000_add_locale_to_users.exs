defmodule Streamix.Repo.Migrations.AddLocaleToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :locale, :string, null: false, default: "pt_BR"
    end

    create constraint(:users, :users_locale_supported, check: "locale IN ('pt_BR', 'en')")
  end
end
