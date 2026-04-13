defmodule Streamix.Iptv.EpisodeAsset do
  @moduledoc """
  Schema for episode media assets (cover, still).
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Streamix.Iptv.Episode

  @asset_types ~w(cover still)

  @type t :: %__MODULE__{}

  schema "episode_assets" do
    field :asset_type, :string
    field :url, :string
    field :position, :integer, default: 0

    belongs_to :episode, Episode

    timestamps(type: :utc_datetime)
  end

  def changeset(asset, attrs) do
    asset
    |> cast(attrs, [:episode_id, :asset_type, :url, :position])
    |> validate_required([:episode_id, :asset_type, :url])
    |> validate_inclusion(:asset_type, @asset_types)
    |> assoc_constraint(:episode)
  end
end
