defmodule Streamix.Repo.Migrations.AddEmbedplayProviderType do
  use Ecto.Migration

  # migration-safety: reviewed
  #
  # Both `up` and `down` drop the `provider_type` check constraint before
  # recreating it. That is safe here for two reasons:
  #
  #   1. Ecto wraps each migration in a transaction, so the drop and the
  #      recreate commit together. No window exists where `providers` is
  #      unconstrained.
  #   2. The new predicate is a strict superset of the old one — every row
  #      that satisfied ('xtream', 'gindex', 'torrent') still satisfies the
  #      replacement. Rows written by the previous release stay valid, so
  #      this needs no expand/contract rollout.
  #
  # `down` is the narrowing direction and therefore refuses to run while any
  # Embedplay provider exists, rather than failing later on a raw constraint
  # violation. It never deletes catalog, history, or provider rows.

  def up do
    drop constraint(:providers, :providers_provider_type_check)

    create constraint(:providers, :providers_provider_type_check,
             check: "provider_type IN ('xtream', 'gindex', 'torrent', 'embedplay')"
           )

    create unique_index(:providers, [:provider_type],
             where: "provider_type = 'embedplay' AND is_system = true",
             name: :providers_embedplay_system_unique
           )
  end

  def down do
    %{rows: [[embedplay_count]]} =
      repo().query!("SELECT count(*) FROM providers WHERE provider_type = 'embedplay'")

    if embedplay_count > 0 do
      raise """
      Refusing to roll back: #{embedplay_count} Embedplay provider(s) still exist.

      Narrowing the check constraint would reject them. Remove or migrate those
      providers deliberately first — this migration will not delete catalog,
      history, or provider rows on your behalf.
      """
    end

    drop index(:providers, [:provider_type], name: :providers_embedplay_system_unique)
    drop constraint(:providers, :providers_provider_type_check)

    create constraint(:providers, :providers_provider_type_check,
             check: "provider_type IN ('xtream', 'gindex', 'torrent')"
           )
  end
end
