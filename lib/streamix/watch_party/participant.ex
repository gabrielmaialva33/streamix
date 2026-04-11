defmodule Streamix.WatchParty.Participant do
  use Ecto.Schema
  import Ecto.Changeset

  schema "watch_party_participants" do
    field :role, :string, default: "viewer"
    field :joined_at, :utc_datetime
    field :left_at, :utc_datetime

    belongs_to :room, Streamix.WatchParty.Room
    belongs_to :user, Streamix.Accounts.User

    timestamps(type: :utc_datetime)
  end

  @valid_roles ~w(host viewer)

  def join_changeset(participant, attrs) do
    participant
    |> cast(attrs, [:room_id, :user_id, :role])
    |> validate_required([:room_id, :user_id])
    |> validate_inclusion(:role, @valid_roles)
    |> put_change(:joined_at, DateTime.truncate(DateTime.utc_now(), :second))
    |> foreign_key_constraint(:room_id)
    |> foreign_key_constraint(:user_id)
    |> unique_constraint([:room_id, :user_id], name: :watch_party_participants_active_unique)
  end

  def leave_changeset(participant) do
    participant
    |> change(left_at: DateTime.truncate(DateTime.utc_now(), :second))
  end
end
