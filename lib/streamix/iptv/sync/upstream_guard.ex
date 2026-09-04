defmodule Streamix.Iptv.Sync.UpstreamGuard do
  @moduledoc """
  Refuses to treat an empty upstream listing as "the provider has nothing".

  Xtream panels answer `200` with an empty JSON array when they are degraded,
  and the sync pipeline cannot tell that apart from a provider that genuinely
  emptied a section. Acting on it deletes the provider's whole catalog, which
  cascades through `catalog_items` into every user's favorites, watch progress
  and watch-party rooms. That loss is unrecoverable, because a later re-sync
  mints new `catalog_items` ids and history can no longer be re-linked.
  """

  import Ecto.Query, warn: false

  require Logger

  alias Streamix.Repo

  @doc """
  Returns `:ok` when the section may proceed.

  Proceeds when upstream listed at least one entry, or when the provider has
  no stored rows for that schema yet (a first sync of an empty section is
  harmless). Returns `{:error, :empty_upstream_catalog}` when upstream is
  empty while rows exist, so the caller aborts before writing counters or
  timestamps and before the orphan pass runs.
  """
  @spec ensure_upstream_present([term()], pos_integer(), keyword()) ::
          :ok | {:error, :empty_upstream_catalog}
  def ensure_upstream_present([_ | _], _provider_id, _opts), do: :ok

  def ensure_upstream_present([], provider_id, opts) do
    schema = Keyword.fetch!(opts, :schema)
    stored = Repo.aggregate(where(schema, provider_id: ^provider_id), :count)

    if stored == 0 do
      :ok
    else
      Logger.error(
        "[Sync] upstream listed an empty catalog for provider #{provider_id} while " <>
          "#{stored} #{inspect(schema)} rows are stored; aborting the section instead " <>
          "of deleting them"
      )

      {:error, :empty_upstream_catalog}
    end
  end
end
