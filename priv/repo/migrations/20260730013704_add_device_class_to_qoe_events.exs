defmodule Streamix.Repo.Migrations.AddDeviceClassToQoeEvents do
  use Ecto.Migration

  def change do
    alter table(:qoe_events) do
      add :device_class, :string, null: false, default: "unknown"
    end
  end
end
