defmodule Streamix.Iptv.WatchProgress do
  @moduledoc """
  Tracks current watch progress per user per content item.
  One record per user+item — updated as user watches.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Streamix.Accounts.User
  alias Streamix.Iptv.CatalogItem

  @type t :: %__MODULE__{}

  schema "watch_progress" do
    field :progress_seconds, :integer, default: 0
    field :duration_seconds, :integer
    field :completed, :boolean, default: false
    field :last_watched_at, :utc_datetime

    belongs_to :user, User
    belongs_to :catalog_item, CatalogItem

    timestamps(type: :utc_datetime)
  end

  @fields ~w(user_id catalog_item_id progress_seconds duration_seconds completed last_watched_at)a

  def changeset(progress, attrs) do
    progress
    |> cast(attrs, @fields)
    |> validate_required([:user_id, :catalog_item_id])
    |> assoc_constraint(:user)
    |> assoc_constraint(:catalog_item)
    |> unique_constraint([:user_id, :catalog_item_id])
  end
end
