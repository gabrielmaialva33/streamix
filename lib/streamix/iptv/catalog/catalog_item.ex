defmodule Streamix.Iptv.CatalogItem do
  @moduledoc """
  Unified content reference (supertable) for favorites, watch progress, and watch party.
  Each content entity (movie, series, episode, live_channel) has exactly one catalog_item.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Streamix.Iptv.{
    Category,
    ContentSourceGroup,
    Episode,
    LiveChannel,
    Movie,
    Provider,
    Series
  }

  @content_types ~w(live_channel movie series episode)

  @type t :: %__MODULE__{}

  schema "catalog_items" do
    field :content_type, :string
    field :source_match_method, :string
    field :source_match_confidence, :integer
    field :source_verified_at, :utc_datetime

    belongs_to :provider, Provider
    belongs_to :source_group, ContentSourceGroup
    has_one :movie, Movie
    has_one :series, Series
    has_one :episode, Episode
    has_one :live_channel, LiveChannel
    many_to_many :categories, Category, join_through: "item_categories"

    timestamps(type: :utc_datetime)
  end

  def changeset(catalog_item, attrs) do
    catalog_item
    |> cast(attrs, [:content_type, :provider_id])
    |> validate_required([:content_type, :provider_id])
    |> validate_inclusion(:content_type, @content_types)
    |> foreign_key_constraint(:provider_id)
  end

  @doc """
  Returns the actual content struct from a catalog item.
  The catalog item must have the appropriate association preloaded.
  """
  def content(%__MODULE__{content_type: "movie", movie: %Movie{} = movie}), do: movie
  def content(%__MODULE__{content_type: "series", series: %Series{} = series}), do: series
  def content(%__MODULE__{content_type: "episode", episode: %Episode{} = episode}), do: episode

  def content(%__MODULE__{content_type: "live_channel", live_channel: %LiveChannel{} = channel}),
    do: channel

  def content(_), do: nil

  @doc """
  Returns the display name for the content.
  """
  def content_name(%__MODULE__{} = item) do
    case content(item) do
      nil -> nil
      content -> Map.get(content, :name) || Map.get(content, :title)
    end
  end

  @doc """
  Returns the icon/poster URL for the content.
  """
  def content_icon(%__MODULE__{} = item) do
    case content(item) do
      nil ->
        nil

      content ->
        Map.get(content, :stream_icon) || Map.get(content, :cover) ||
          Map.get(content, :still_path)
    end
  end

  def content_types, do: @content_types
end
