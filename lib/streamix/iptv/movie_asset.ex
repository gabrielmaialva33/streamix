defmodule Streamix.Iptv.MovieAsset do
  @moduledoc """
  Schema for movie media assets (poster, backdrop, image, icon).
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Streamix.Iptv.Movie

  @asset_types ~w(poster backdrop image icon)

  @type t :: %__MODULE__{}

  schema "movie_assets" do
    field :asset_type, :string
    field :url, :string
    field :position, :integer, default: 0

    belongs_to :movie, Movie

    timestamps(type: :utc_datetime)
  end

  def changeset(asset, attrs) do
    asset
    |> cast(attrs, [:movie_id, :asset_type, :url, :position])
    |> validate_required([:movie_id, :asset_type, :url])
    |> validate_inclusion(:asset_type, @asset_types)
    |> assoc_constraint(:movie)
  end
end
