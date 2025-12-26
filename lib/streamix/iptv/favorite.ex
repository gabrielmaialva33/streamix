defmodule Streamix.Iptv.Favorite do
  @moduledoc """
  Schema for user favorites (polymorphic).
  Supports: live_channel, movie, series
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Streamix.Accounts.User

  @content_types ~w(live_channel movie series)

  schema "favorites" do
    field :content_type, :string
    field :content_id, :integer
    field :content_name, :string
    field :content_icon, :string

    belongs_to :user, User

    timestamps(type: :utc_datetime)
  end

  def changeset(favorite, attrs) do
    favorite
    |> cast(attrs, [:content_type, :content_id, :content_name, :content_icon, :user_id])
    |> validate_required([:content_type, :content_id, :user_id])
    |> validate_inclusion(:content_type, @content_types)
    |> unique_constraint([:user_id, :content_type, :content_id])
    |> foreign_key_constraint(:user_id)
  end
end
