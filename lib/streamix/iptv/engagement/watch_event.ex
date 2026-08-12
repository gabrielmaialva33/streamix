defmodule Streamix.Iptv.WatchEvent do
  @moduledoc """
  Schema retained for immutable, session-level watch events.

  Current playback progress writes use `Streamix.Iptv.WatchProgress`; callers
  must not assume that every progress update creates a historical event.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Streamix.Iptv.CatalogItem

  @type t :: %__MODULE__{}

  schema "watch_events" do
    field :user_id, :id
    field :watched_at, :utc_datetime
    field :session_seconds, :integer
    field :progress_seconds, :integer
    field :completed, :boolean, default: false
    field :ip_address, Streamix.Ecto.Inet
    field :device_type, :string

    belongs_to :catalog_item, CatalogItem

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @fields ~w(user_id catalog_item_id watched_at session_seconds progress_seconds
             completed ip_address device_type)a

  def changeset(event, attrs) do
    event
    |> cast(attrs, @fields)
    |> validate_required([:user_id, :catalog_item_id, :watched_at])
    |> foreign_key_constraint(:user_id)
    |> assoc_constraint(:catalog_item)
  end
end
