defmodule Streamix.Iptv.WatchHistory do
  @moduledoc """
  Schema for user watch history (polymorphic).
  Supports: live_channel, movie, episode
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Streamix.Accounts.User

  @content_types ~w(live_channel movie episode)

  schema "watch_history" do
    field :content_type, :string
    field :content_id, :integer
    field :watched_at, :utc_datetime
    field :duration_seconds, :integer
    field :progress_seconds, :integer, default: 0
    field :completed, :boolean, default: false
    field :content_name, :string
    field :content_icon, :string
    field :parent_name, :string
    field :episode_info, :string

    belongs_to :user, User

    timestamps(type: :utc_datetime)
  end

  def changeset(history, attrs) do
    history
    |> cast(attrs, [
      :content_type,
      :content_id,
      :watched_at,
      :duration_seconds,
      :progress_seconds,
      :completed,
      :content_name,
      :content_icon,
      :parent_name,
      :episode_info,
      :user_id
    ])
    |> validate_required([:content_type, :content_id, :watched_at, :user_id])
    |> validate_inclusion(:content_type, @content_types)
    |> unique_constraint([:user_id, :content_type, :content_id])
    |> foreign_key_constraint(:user_id)
  end
end
