defmodule Streamix.Iptv.Favorite do
  @moduledoc """
  Schema for user favorites normalized around concrete content references.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Streamix.Accounts.User
  alias Streamix.Iptv.{Episode, LiveChannel, Movie, Series}

  @type t :: %__MODULE__{}

  schema "favorites" do
    field :content_type, :string, virtual: true
    field :content_id, :integer, virtual: true
    field :content_name, :string, virtual: true
    field :content_icon, :string, virtual: true

    belongs_to :user, User
    belongs_to :live_channel, LiveChannel
    belongs_to :movie, Movie
    belongs_to :series, Series
    belongs_to :episode, Episode

    timestamps(type: :utc_datetime)
  end

  @target_fields [:live_channel_id, :movie_id, :series_id, :episode_id]

  def changeset(favorite, attrs) do
    favorite
    |> cast(attrs, [:user_id | @target_fields])
    |> validate_required([:user_id])
    |> validate_exactly_one_target()
    |> unique_constraint(:user_id, name: :favorites_user_live_channel_unique_idx)
    |> unique_constraint(:user_id, name: :favorites_user_movie_unique_idx)
    |> unique_constraint(:user_id, name: :favorites_user_series_unique_idx)
    |> unique_constraint(:user_id, name: :favorites_user_episode_unique_idx)
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:live_channel_id)
    |> foreign_key_constraint(:movie_id)
    |> foreign_key_constraint(:series_id)
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
