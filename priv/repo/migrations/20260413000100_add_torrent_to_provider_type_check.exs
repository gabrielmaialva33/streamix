defmodule Streamix.Repo.Migrations.AddTorrentToProviderTypeCheck do
  @moduledoc """
  PR-D dependency: extends the providers.provider_type CHECK constraint
  to allow `:torrent` so `TorrentProvider.ensure_exists!/0` can insert
  the system aggregator row. The original baseline only listed
  ('xtream', 'gindex'); the schema enum was extended in code but the
  DB-level CHECK was never updated.
  """

  use Ecto.Migration

  def up do
    execute("ALTER TABLE providers DROP CONSTRAINT IF EXISTS providers_provider_type_check")

    execute(
      "ALTER TABLE providers ADD CONSTRAINT providers_provider_type_check " <>
        "CHECK (provider_type IN ('xtream', 'gindex', 'torrent'))"
    )
  end

  def down do
    execute("ALTER TABLE providers DROP CONSTRAINT IF EXISTS providers_provider_type_check")

    execute(
      "ALTER TABLE providers ADD CONSTRAINT providers_provider_type_check " <>
        "CHECK (provider_type IN ('xtream', 'gindex'))"
    )
  end
end
