defmodule Streamix.Billing.PlaybackSession do
  @moduledoc """
  Active playback slot used to enforce plan screen limits.

  It records that a screen is in use, never what it plays: the limit only
  needs a count, and the content would tell the operator what the user
  watches (docs/privacy.md).
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "playback_sessions" do
    field :user_id, :id
    field :session_id, :string
    field :status, :string, default: "active"
    field :started_at, :utc_datetime
    field :last_seen_at, :utc_datetime
    field :ended_at, :utc_datetime
    field :metadata, :map, default: %{}
    field :client_id, :string

    timestamps(type: :utc_datetime)
  end

  @statuses ~w(active ended)

  def changeset(playback_session, attrs) do
    playback_session
    |> cast(attrs, [
      :user_id,
      :session_id,
      :status,
      :started_at,
      :last_seen_at,
      :ended_at,
      :metadata,
      :client_id
    ])
    |> validate_required([
      :user_id,
      :session_id,
      :status,
      :started_at,
      :last_seen_at
    ])
    |> validate_inclusion(:status, @statuses)
    |> validate_length(:client_id, max: 64)
    |> foreign_key_constraint(:user_id)
    |> unique_constraint(:session_id)
  end
end
