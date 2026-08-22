defmodule Streamix.WatchParty.Room do
  use Ecto.Schema
  import Ecto.Changeset

  schema "watch_party_rooms" do
    field :host_user_id, :id
    field :catalog_item_id, :id
    field :catalog_item, :map, virtual: true
    field :invite_code, :string
    field :status, :string, default: "active"
    field :max_participants, :integer, default: 10
    field :settings, :map, default: %{}
    field :source_type, :string
    field :source_id, :integer
    field :playback_state, :string, default: "paused"
    field :playback_position, :float, default: 0.0
    field :playback_buffering, :boolean, default: false
    field :playback_version, :integer, default: 0
    field :playback_updated_at, :utc_datetime_usec
    field :last_activity_at, :utc_datetime_usec
    field :ended_at, :utc_datetime
    field :ended_reason, :string

    has_many :participants, Streamix.WatchParty.Participant
    has_many :messages, Streamix.WatchParty.Message

    timestamps(type: :utc_datetime)
  end

  def create_changeset(room, attrs) do
    room
    |> cast(attrs, [
      :host_user_id,
      :catalog_item_id,
      :max_participants,
      :settings,
      :source_type,
      :source_id
    ])
    |> validate_required([:host_user_id, :catalog_item_id, :source_type, :source_id])
    |> validate_number(:max_participants, greater_than: 1, less_than_or_equal_to: 50)
    |> validate_inclusion(
      :source_type,
      ~w(live_channel movie episode gindex gindex_episode torrent)
    )
    |> validate_number(:source_id, greater_than: 0)
    |> put_change(:invite_code, generate_invite_code())
    |> put_change(:status, "active")
    |> put_change(:last_activity_at, DateTime.utc_now())
    |> unique_constraint(:invite_code)
    |> unique_constraint([:host_user_id, :catalog_item_id],
      name: :watch_party_rooms_host_content_active_unique
    )
    |> foreign_key_constraint(:host_user_id)
    |> foreign_key_constraint(:catalog_item_id)
  end

  def snapshot_changeset(room, attrs) do
    room
    |> cast(attrs, [
      :catalog_item_id,
      :source_type,
      :source_id,
      :playback_state,
      :playback_position,
      :playback_buffering,
      :playback_version,
      :playback_updated_at,
      :last_activity_at
    ])
    |> validate_inclusion(
      :source_type,
      ~w(live_channel movie episode gindex gindex_episode torrent)
    )
    |> validate_number(:source_id, greater_than: 0)
    |> validate_inclusion(:playback_state, ~w(playing paused))
    |> validate_number(:playback_position, greater_than_or_equal_to: 0)
    |> validate_number(:playback_version, greater_than_or_equal_to: 0)
    |> foreign_key_constraint(:catalog_item_id)
  end

  def end_changeset(room, reason \\ "host_ended") do
    room
    |> change(
      status: "ended",
      ended_at: DateTime.utc_now(:second),
      ended_reason: reason,
      playback_state: "paused",
      playback_buffering: false,
      last_activity_at: DateTime.utc_now()
    )
  end

  # 8 random bytes → 13 base32 chars, truncated to 12 → ~60 bits of entropy.
  # 32-bit codes (the previous 6-char form) brute-force in minutes against an
  # unauthenticated lookup; 60 bits push that into geological timescales.
  # Lookup remains rate-limited downstream (see WatchPartyLive.Index/Join).
  def generate_invite_code do
    :crypto.strong_rand_bytes(8)
    |> Base.encode32(case: :lower, padding: false)
    |> binary_part(0, 12)
  end
end
