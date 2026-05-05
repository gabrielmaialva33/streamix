defmodule Streamix.Billing.PlaybackSession do
  @moduledoc """
  Active playback slot used to enforce plan screen limits.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Streamix.Accounts.User

  schema "playback_sessions" do
    field :session_id, :string
    field :content_type, :string
    field :content_id, :integer
    field :status, :string, default: "active"
    field :started_at, :utc_datetime
    field :last_seen_at, :utc_datetime
    field :ended_at, :utc_datetime
    field :metadata, :map, default: %{}

    belongs_to :user, User

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
      :metadata
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
    |> foreign_key_constraint(:user_id)
    |> unique_constraint(:session_id)
  end
end
