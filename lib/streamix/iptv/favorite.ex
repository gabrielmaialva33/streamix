defmodule Streamix.Iptv.Favorite do
  use Ecto.Schema
  import Ecto.Changeset

  alias Streamix.Accounts.User
  alias Streamix.Iptv.Channel

  schema "favorites" do
    belongs_to :user, User
    belongs_to :channel, Channel

    timestamps()
  end

  def changeset(favorite, attrs) do
    favorite
    |> cast(attrs, [:user_id, :channel_id])
    |> validate_required([:user_id, :channel_id])
    |> unique_constraint([:user_id, :channel_id])
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:channel_id)
  end
end
