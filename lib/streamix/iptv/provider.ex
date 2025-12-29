defmodule Streamix.Iptv.Provider do
  @moduledoc """
  Schema for IPTV providers (Xtream Codes compatible servers).
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Streamix.Accounts.User
  alias Streamix.Iptv.{Category, EpgProgram, LiveChannel, Movie, Series}

  schema "providers" do
    field :name, :string
    field :url, :string
    field :username, :string
    field :password, :string, redact: true
    field :is_active, :boolean, default: true
    field :sync_status, :string, default: "idle"
    field :visibility, Ecto.Enum, values: [:private, :public, :global], default: :private
    field :is_system, :boolean, default: false

    # Contadores por tipo
    field :live_channels_count, :integer, default: 0
    field :movies_count, :integer, default: 0
    field :series_count, :integer, default: 0

    # Timestamps de sync por tipo
    field :live_synced_at, :utc_datetime
    field :vod_synced_at, :utc_datetime
    field :series_synced_at, :utc_datetime
    field :epg_synced_at, :utc_datetime
    field :epg_sync_interval_hours, :integer, default: 6

    # Info do servidor (JSON)
    field :server_info, :map

    belongs_to :user, User
    has_many :categories, Category
    has_many :live_channels, LiveChannel
    has_many :movies, Movie
    has_many :series, Series
    has_many :epg_programs, EpgProgram

    timestamps(type: :utc_datetime)
  end

  @required_fields ~w(name url username password)a
  @optional_fields ~w(user_id is_active sync_status visibility is_system
                      live_channels_count movies_count series_count
                      live_synced_at vod_synced_at series_synced_at
                      epg_synced_at epg_sync_interval_hours server_info)a

  def changeset(provider, attrs) do
    provider
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_length(:name, min: 1, max: 100)
    |> validate_url(:url)
    |> validate_inclusion(:visibility, [:private, :public, :global])
    |> maybe_require_user_id()
    |> unique_constraint([:user_id, :url, :username])
    |> foreign_key_constraint(:user_id)
  end

  # Provider de sistema (global) não precisa de user_id
  defp maybe_require_user_id(changeset) do
    if get_field(changeset, :is_system) do
      changeset
    else
      validate_required(changeset, [:user_id])
    end
  end

  def sync_changeset(provider, attrs) do
    provider
    |> cast(attrs, [
      :sync_status,
      :live_channels_count,
      :movies_count,
      :series_count,
      :live_synced_at,
      :vod_synced_at,
      :series_synced_at,
      :epg_synced_at,
      :server_info
    ])
  end

  defp validate_url(changeset, field) do
    validate_change(changeset, field, fn _, value ->
      case URI.parse(value) do
        %URI{scheme: scheme} when scheme in ["http", "https"] -> []
        _ -> [{field, "must be a valid HTTP/HTTPS URL"}]
      end
    end)
  end
end
