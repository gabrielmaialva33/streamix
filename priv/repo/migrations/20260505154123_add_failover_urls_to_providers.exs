defmodule Streamix.Repo.Migrations.AddFailoverUrlsToProviders do
  use Ecto.Migration

  def change do
    alter table(:providers) do
      # Failover host alternatives. Empty by default (single-URL providers).
      # When upstream redirects to a known "blocked" pattern (configurable
      # via :failover_redirect_patterns) or returns a terminal status,
      # VodProxy rotates through `[url | urls]` until one succeeds.
      add :urls, {:array, :string}, default: [], null: false
    end
  end
end
