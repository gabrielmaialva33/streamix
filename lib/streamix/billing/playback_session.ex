defmodule Streamix.Billing.PlaybackSession do
  @moduledoc """
  Active playback slot used to enforce plan screen limits.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "playback_sessions" do
    field :user_id, :id
    field :session_id, :string
    field :content_type, :string
    field :content_id, :integer
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
      :content_type,
      :content_id,
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
      :content_type,
      :content_id,
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
