defmodule Streamix.WatchParty.Room do
  use Ecto.Schema
  import Ecto.Changeset

  schema "watch_party_rooms" do
    field :invite_code, :string
    field :content_type, :string
    field :content_id, :integer
    field :content_name, :string
    field :content_icon, :string
    field :status, :string, default: "active"
    field :max_participants, :integer, default: 10
    field :settings, :map, default: %{}
    field :ended_at, :utc_datetime

    belongs_to :host_user, Streamix.Accounts.User, foreign_key: :host_user_id
    has_many :participants, Streamix.WatchParty.Participant
    has_many :messages, Streamix.WatchParty.Message

    timestamps()
  end

  @valid_content_types ~w(live_channel movie episode gindex gindex_episode)

  def create_changeset(room, attrs) do
    room
    |> cast(attrs, [:host_user_id, :content_type, :content_id, :content_name, :content_icon, :max_participants, :settings])
    |> validate_required([:host_user_id, :content_type, :content_id])
    |> validate_inclusion(:content_type, @valid_content_types)
    |> validate_number(:max_participants, greater_than: 1, less_than_or_equal_to: 50)
    |> put_change(:invite_code, generate_invite_code())
    |> put_change(:status, "active")
    |> unique_constraint(:invite_code)
    |> foreign_key_constraint(:host_user_id)
  end

  def end_changeset(room) do
    room
    |> change(status: "ended", ended_at: DateTime.truncate(DateTime.utc_now(), :second))
  end

  def generate_invite_code do
    :crypto.strong_rand_bytes(4)
    |> Base.encode32(case: :lower, padding: false)
    |> binary_part(0, 6)
  end
end
