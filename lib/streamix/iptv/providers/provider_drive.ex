defmodule Streamix.Iptv.ProviderDrive do
  @moduledoc """
  Schema for provider GIndex drives.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Streamix.Iptv.Provider

  @type t :: %__MODULE__{}

  schema "provider_drives" do
    field :name, :string
    field :drive_url, :string
    field :drive_type, :string
    field :metadata, :map, default: %{}

    belongs_to :provider, Provider

    timestamps(type: :utc_datetime)
  end

  def changeset(drive, attrs) do
    drive
    |> cast(attrs, [:provider_id, :name, :drive_url, :drive_type, :metadata])
    |> validate_required([:provider_id, :name])
    |> assoc_constraint(:provider)
  end
end
