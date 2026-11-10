defmodule Streamix.Repo.Migrations.AddErrorCodeToQoeEvents do
  use Ecto.Migration

  def change do
    alter table(:qoe_events) do
      add :error_code, :string
    end
  end
end
