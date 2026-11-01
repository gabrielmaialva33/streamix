defmodule Streamix.Iptv.Favorite do
  @moduledoc """
  A sealed favorite. Like `Streamix.Iptv.WatchProgress`, the row only holds
  an HMAC of the content under the owner's library key and the ciphertext of
  the reference; `Streamix.Iptv.Favorites` opens and writes it.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "sealed_favorites" do
    field :user_id, :id
    field :item_digest, :binary
    field :sealed, :binary, redact: true
  end

  def changeset(favorite, attrs) do
    favorite
    |> change(attrs)
    |> validate_required([:user_id, :item_digest, :sealed])
    |> foreign_key_constraint(:user_id)
    |> unique_constraint([:user_id, :item_digest])
  end
end
