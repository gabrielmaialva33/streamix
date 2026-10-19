defmodule Streamix.Repo.Migrations.AddSendXDomainToProviders do
  use Ecto.Migration

  def change do
    alter table(:providers) do
      add :send_x_domain, :boolean, default: false, null: false
    end
  end
end
