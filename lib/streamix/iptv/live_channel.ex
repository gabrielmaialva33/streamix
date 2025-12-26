defmodule Streamix.Iptv.LiveChannel do
  @moduledoc """
  Schema for live TV channels.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Streamix.Iptv.{Category, Provider, XtreamClient}

  schema "live_channels" do
    field :stream_id, :integer
    field :name, :string
    field :stream_icon, :string
    field :epg_channel_id, :string
    field :tv_archive, :boolean, default: false
    field :tv_archive_duration, :integer
    field :direct_source, :string

    belongs_to :provider, Provider
    many_to_many :categories, Category, join_through: "live_channel_categories"

    timestamps(type: :utc_datetime)
  end

  def changeset(channel, attrs) do
    channel
    |> cast(attrs, [
      :stream_id,
      :name,
      :stream_icon,
      :epg_channel_id,
      :tv_archive,
      :tv_archive_duration,
      :direct_source,
      :provider_id
    ])
    |> validate_required([:stream_id, :name, :provider_id])
    |> unique_constraint([:provider_id, :stream_id])
    |> foreign_key_constraint(:provider_id)
  end

  @doc """
  Builds the stream URL for this live channel.
  """
  def stream_url(%__MODULE__{stream_id: stream_id}, %Provider{} = provider) do
    XtreamClient.live_stream_url(provider.url, provider.username, provider.password, stream_id)
  end
end
