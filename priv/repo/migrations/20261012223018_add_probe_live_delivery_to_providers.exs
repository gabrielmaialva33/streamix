defmodule Streamix.Repo.Migrations.AddProbeLiveDeliveryToProviders do
  use Ecto.Migration

  # `probe_live_delivery` is an operator-only provider switch: each live
  # channel of such a provider is probed at play time and served as HLS
  # through the gateway, as TS through the existing live proxy, or reported
  # unavailable (see docs/xtream-live-hls.md). It is never cast from user
  # params, and providers without it keep the TS live path untouched.
  #
  # Expand-only: the column is additive with a constant default
  # (metadata-only on PostgreSQL 11+), and the previous release neither reads
  # nor writes it.
  def change do
    alter table(:providers) do
      add :probe_live_delivery, :boolean, null: false, default: false
    end
  end
end
