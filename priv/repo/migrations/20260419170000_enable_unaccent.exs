defmodule Streamix.Repo.Migrations.EnableUnaccent do
  @moduledoc """
  Enables the `unaccent` extension so lexical search can fold diacritics
  (e.g. `Pokémon` → `pokemon`) before comparing. Paired with `pg_trgm`
  (already installed) it lets queries like `pokemon` find `Pokémon`,
  `Pokemón`, or the mis-typed `pokmon` via trigram similarity.

  `CREATE EXTENSION IF NOT EXISTS` is idempotent; the DROP in change/1
  is left as a no-op because removing the extension in a rollback would
  break every search query currently in flight.
  """
  use Ecto.Migration

  def up, do: execute("CREATE EXTENSION IF NOT EXISTS unaccent")

  # Intentionally a no-op: the extension is shared infrastructure; a
  # rollback shouldn't yank it out from under queries that are still
  # referencing unaccent() in functions/indexes.
  def down, do: :ok
end
