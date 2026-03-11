defmodule Streamix.WatchParty.Message do
  use Ecto.Schema
  import Ecto.Changeset

  @timestamps_opts [updated_at: false]

  schema "watch_party_messages" do
    field :content, :string
    field :type, :string, default: "text"

    belongs_to :room, Streamix.WatchParty.Room
    belongs_to :user, Streamix.Accounts.User

    timestamps(type: :utc_datetime_usec)
  end

  @valid_types ~w(text reaction system)

  def changeset(message, attrs) do
    message
    |> cast(attrs, [:room_id, :user_id, :content, :type])
    |> validate_required([:room_id, :user_id, :content])
    |> validate_inclusion(:type, @valid_types)
    |> validate_length(:content, max: 500)
    |> foreign_key_constraint(:room_id)
    |> foreign_key_constraint(:user_id)
  end
end
