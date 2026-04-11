defmodule Streamix.Iptv.WatchHistory do
  @moduledoc """
  Schema for user watch history normalized around concrete playable content
  references.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Streamix.Accounts.User
  alias Streamix.Iptv.{Episode, LiveChannel, Movie}

  @type t :: %__MODULE__{}

  schema "watch_history" do
    field :content_type, :string, virtual: true
    field :content_id, :integer, virtual: true
    field :watched_at, :utc_datetime
    field :duration_seconds, :integer
    field :progress_seconds, :integer, default: 0
    field :completed, :boolean, default: false
    field :content_name, :string, virtual: true
    field :content_icon, :string, virtual: true
    field :ip_address, :string
    field :device_type, :string

    belongs_to :user, User
    belongs_to :live_channel, LiveChannel
    belongs_to :movie, Movie
    belongs_to :episode, Episode

    timestamps(type: :utc_datetime)
  end

  @target_fields [:live_channel_id, :movie_id, :episode_id]

  def changeset(history, attrs) do
    history
    |> cast(attrs, [
      :watched_at,
      :duration_seconds,
      :progress_seconds,
      :completed,
      :user_id,
      :live_channel_id,
      :movie_id,
      :episode_id,
      :ip_address,
      :device_type
    ])
    |> validate_required([:watched_at, :user_id])
    |> validate_exactly_one_target()
    |> unique_constraint(:user_id, name: :watch_history_user_live_channel_unique_idx)
    |> unique_constraint(:user_id, name: :watch_history_user_movie_unique_idx)
    |> unique_constraint(:user_id, name: :watch_history_user_episode_unique_idx)
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:live_channel_id)
    |> foreign_key_constraint(:movie_id)
    |> foreign_key_constraint(:episode_id)
  end

  defp validate_exactly_one_target(changeset) do
    count =
      @target_fields
      |> Enum.count(&get_field(changeset, &1))

    if count == 1 do
      changeset
    else
      add_error(changeset, :content_type, "must reference exactly one content target")
    end
  end
end
