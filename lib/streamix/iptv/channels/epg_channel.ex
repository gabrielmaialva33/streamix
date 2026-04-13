defmodule Streamix.Iptv.EpgChannel do
  @moduledoc """
  Schema for EPG channels — links provider EPG channel IDs to live channels.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Streamix.Iptv.{LiveChannel, Provider}

  @type t :: %__MODULE__{}

  schema "epg_channels" do
    field :external_id, :string
    field :name, :string
    field :icon, :string

    belongs_to :provider, Provider
    belongs_to :live_channel, LiveChannel

    timestamps(type: :utc_datetime)
  end

  def changeset(channel, attrs) do
    channel
    |> cast(attrs, [:external_id, :name, :icon, :provider_id, :live_channel_id])
    |> validate_required([:external_id, :provider_id])
    |> unique_constraint([:provider_id, :external_id])
    |> assoc_constraint(:provider)
  end
end
