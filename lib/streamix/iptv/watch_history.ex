defmodule Streamix.Iptv.WatchHistory do
  @moduledoc """
  Schema for user watch history.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Streamix.Accounts.User
  alias Streamix.Iptv.Channel

  schema "watch_history" do
    field :watched_at, :utc_datetime
    field :duration_seconds, :integer, default: 0

    belongs_to :user, User
    belongs_to :channel, Channel

    timestamps()
  end

  def changeset(watch_history, attrs) do
    watch_history
    |> cast(attrs, [:watched_at, :duration_seconds, :user_id, :channel_id])
    |> validate_required([:watched_at, :user_id, :channel_id])
    |> validate_number(:duration_seconds, greater_than_or_equal_to: 0)
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:channel_id)
  end
end
