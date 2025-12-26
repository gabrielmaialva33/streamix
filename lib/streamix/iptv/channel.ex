defmodule Streamix.Iptv.Channel do
  use Ecto.Schema
  import Ecto.Changeset

  alias Streamix.Iptv.Provider

  schema "channels" do
    field :name, :string
    field :logo_url, :string
    field :stream_url, :string
    field :tvg_id, :string
    field :tvg_name, :string
    field :group_title, :string

    belongs_to :provider, Provider

    timestamps()
  end

  @required_fields ~w(name stream_url provider_id)a
  @optional_fields ~w(logo_url tvg_id tvg_name group_title)a

  def changeset(channel, attrs) do
    channel
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> foreign_key_constraint(:provider_id)
  end
end
