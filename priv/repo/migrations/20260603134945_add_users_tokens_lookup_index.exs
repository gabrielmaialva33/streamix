defmodule Streamix.Repo.Migrations.AddUsersTokensLookupIndex do
  @moduledoc """
  Adds a covering index for `(user_id, context)` on `users_tokens`.

  Session logout, "log me out everywhere", and per-context revoke flows
  filter by user_id + context. The existing single-column index on
  `user_id` is fine for "delete all my tokens", but a composite avoids
  scanning every token for a user when only one context is targeted.
  """
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS
      users_tokens_user_id_context_index
      ON users_tokens (user_id, context)
    """)
  end

  def down do
    execute("DROP INDEX CONCURRENTLY IF EXISTS users_tokens_user_id_context_index")
  end
end
