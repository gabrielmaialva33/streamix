defmodule Streamix.Repo.Migrations.NormalizeStreamIconEmptyStrings do
  use Ecto.Migration

  def up do
    # Normalize empty string image fields to NULL for consistent handling
    # This prevents the UI from trying to load empty src URLs

    execute("UPDATE live_channels SET stream_icon = NULL WHERE stream_icon = ''")
    execute("UPDATE movies SET stream_icon = NULL WHERE stream_icon = ''")
    execute("UPDATE series SET cover = NULL WHERE cover = ''")
    execute("UPDATE episodes SET cover = NULL WHERE cover = ''")
    execute("UPDATE episodes SET still_path = NULL WHERE still_path = ''")
  end

  def down do
    # No-op: converting NULL back to empty string would be lossy
    # (we can't distinguish originally-NULL from normalized-NULL)
    :ok
  end
end
