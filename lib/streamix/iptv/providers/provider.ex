defmodule Streamix.Iptv.Provider do
  @moduledoc """
  Schema for IPTV providers (Xtream Codes compatible servers).
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Streamix.Accounts.User
  alias Streamix.Iptv.{Category, EpgChannel, LiveChannel, Movie, ProviderDrive, Series}

  @type t :: %__MODULE__{}

  schema "providers" do
    field :name, :string
    field :url, :string
    field :urls, {:array, :string}, default: []
    field :username, :string
    field :password, Streamix.Iptv.EncryptedField, redact: true
    field :is_active, :boolean, default: true
    field :sync_status, :string, default: "idle"
    field :visibility, Ecto.Enum, values: [:private, :public, :global], default: :private
    field :is_system, :boolean, default: false

    # Provider type: xtream (default), gindex, or torrent
    field :provider_type, Ecto.Enum, values: [:xtream, :gindex, :torrent], default: :xtream
    field :gindex_url, :string

    # Counters by type
    field :live_channels_count, :integer, default: 0
    field :movies_count, :integer, default: 0
    field :series_count, :integer, default: 0

    # Sync timestamps by type
    field :live_synced_at, :utc_datetime
    field :vod_synced_at, :utc_datetime
    field :series_synced_at, :utc_datetime
    field :epg_synced_at, :utc_datetime
    field :epg_sync_interval_hours, :integer, default: 6

    # Server info (JSON)
    field :server_info, :map

    belongs_to :user, User
    has_many :categories, Category
    has_many :live_channels, LiveChannel
    has_many :movies, Movie
    has_many :series, Series
    has_many :epg_channels, EpgChannel
    has_many :drives, ProviderDrive

    timestamps(type: :utc_datetime)
  end

  @all_fields ~w(name url urls username password is_active sync_status visibility is_system
                      live_channels_count movies_count series_count
                      live_synced_at vod_synced_at series_synced_at
                      epg_synced_at epg_sync_interval_hours server_info
                      provider_type gindex_url)a

  @user_fields ~w(name url urls username password is_active visibility epg_sync_interval_hours)a

  @doc """
  Returns the failover-aware URL chain for a provider: the primary `url`
  followed by any registered alternates in `urls`. Duplicates are removed
  while preserving order.
  """
  @spec url_chain(t()) :: [String.t()]
  def url_chain(%__MODULE__{url: url, urls: urls}) do
    Enum.uniq([url | List.wrap(urls)] |> Enum.reject(&(is_nil(&1) or &1 == "")))
  end

  def changeset(provider, attrs) do
    provider
    |> cast(attrs, @all_fields)
    |> validate_required([:name, :url])
    |> validate_length(:name, min: 1, max: 100)
    |> validate_url(:url)
    |> validate_inclusion(:visibility, [:private, :public, :global])
    |> maybe_require_user_id()
    |> maybe_require_credentials()
    |> unique_constraint([:user_id, :url, :username])
    |> foreign_key_constraint(:user_id)
  end

  @doc """
  Changeset for a provider managed by its owner.

  System identity, adapter type, sync state, counters and server metadata are
  intentionally not accepted from user-controlled params.
  """
  @spec user_changeset(t(), map()) :: Ecto.Changeset.t()
  def user_changeset(provider, attrs) do
    provider
    |> cast(attrs, @user_fields)
    |> put_change(:is_system, false)
    |> put_change(:provider_type, :xtream)
    |> validate_required([:name, :url, :user_id, :username, :password])
    |> validate_length(:name, min: 1, max: 100)
    |> validate_url(:url)
    |> validate_inclusion(:visibility, [:private, :public])
    |> unique_constraint([:user_id, :url, :username])
    |> foreign_key_constraint(:user_id)
  end

  # System provider (global) does not need user_id
  defp maybe_require_user_id(changeset) do
    if get_field(changeset, :is_system) do
      changeset
    else
      validate_required(changeset, [:user_id])
    end
  end

  # Virtual/system providers don't need username/password.
  defp maybe_require_credentials(changeset) do
    if get_field(changeset, :provider_type) in [:gindex, :torrent] do
      changeset
    else
      validate_required(changeset, [:username, :password])
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
      provider_type = get_field(changeset, :provider_type)

      case URI.new(value) do
        {:ok, %URI{scheme: scheme, host: host, userinfo: nil}}
        when scheme in ["http", "https"] and is_binary(host) and host != "" ->
          []

        {:ok, %URI{scheme: "torrent", host: host}}
        when provider_type == :torrent and is_binary(host) and host != "" ->
          []

        _ ->
          [{field, "must be a valid HTTP/HTTPS URL"}]
      end
    end)
  end
end
