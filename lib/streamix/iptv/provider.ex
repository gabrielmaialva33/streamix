defmodule Streamix.Iptv.Provider do
  use Ecto.Schema
  import Ecto.Changeset

  alias Streamix.Accounts.User
  alias Streamix.Iptv.Channel

  schema "providers" do
    field :name, :string
    field :url, :string
    field :username, :string
    field :password, :string, redact: true
    field :is_active, :boolean, default: true
    field :last_synced_at, :utc_datetime
    field :channels_count, :integer, default: 0
    field :sync_status, :string, default: "idle"

    belongs_to :user, User
    has_many :channels, Channel

    timestamps()
  end

  @required_fields ~w(name url username password user_id)a
  @optional_fields ~w(is_active last_synced_at channels_count sync_status)a

  def changeset(provider, attrs) do
    provider
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_length(:name, min: 1, max: 100)
    |> validate_url(:url)
    |> unique_constraint([:user_id, :url, :username])
    |> foreign_key_constraint(:user_id)
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
