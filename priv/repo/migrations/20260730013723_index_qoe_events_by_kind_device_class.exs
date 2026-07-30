defmodule Streamix.Repo.Migrations.IndexQoeEventsByKindDeviceClass do
  use Ecto.Migration

  @disable_ddl_transaction true

  def change do
    create index(:qoe_events, [:kind, :device_class, :inserted_at], concurrently: true)
  end
end
