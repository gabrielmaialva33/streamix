defmodule Streamix.Repo.Migrations.MakeProviderCredentialsNullable do
  use Ecto.Migration

  def change do
    alter table(:providers) do
      modify :username, :string, null: true
      modify :password, :string, null: true
    end
  end
end
