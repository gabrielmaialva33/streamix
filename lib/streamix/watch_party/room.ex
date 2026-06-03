defmodule Streamix.WatchParty.Room do
  use Ecto.Schema
  import Ecto.Changeset

  alias Streamix.Iptv.CatalogItem

  schema "watch_party_rooms" do
    field :invite_code, :string
    field :status, :string, default: "active"
    field :max_participants, :integer, default: 10
    field :settings, :map, default: %{}
    field :ended_at, :utc_datetime

    belongs_to :host_user, Streamix.Accounts.User, foreign_key: :host_user_id
    belongs_to :catalog_item, CatalogItem
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
      :settings
    ])
    |> validate_required([:host_user_id, :catalog_item_id])
    |> validate_number(:max_participants, greater_than: 1, less_than_or_equal_to: 50)
    |> put_change(:invite_code, generate_invite_code())
    |> put_change(:status, "active")
    |> unique_constraint(:invite_code)
    |> assoc_constraint(:host_user)
    |> assoc_constraint(:catalog_item)
  end

  def end_changeset(room) do
    room
    |> change(status: "ended", ended_at: DateTime.truncate(DateTime.utc_now(), :second))
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
