defmodule Streamix.Iptv.WatchProgress do
  @moduledoc """
  Sealed playback progress: one row per user and content item.

  The row never says which content it is about. `item_digest` is an HMAC
  under the owner's library key and `sealed` is the AES-256-GCM ciphertext of
  the progress itself, including when it was last watched, so reading the
  table without that key reveals only how many entries a user has.
  `Streamix.Iptv.History` opens and writes these rows.
  """
  use Ecto.Schema

  @type t :: %__MODULE__{}

  schema "sealed_watch_progress" do
    field :user_id, :id
    field :item_digest, :binary
    field :sealed, :binary, redact: true
  end
end
