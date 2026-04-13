defmodule Streamix.Accounts.AccessLog do
  @moduledoc """
  Schema for tracking user access logs with IP and device info.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "access_logs" do
    field :ip_address, Streamix.Ecto.Inet
    field :user_agent, :string
    field :path, :string
    field :method, :string
    field :country, :string
    field :city, :string
    field :device_type, :string
    field :browser, :string
    field :os, :string

    belongs_to :user, Streamix.Accounts.User

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @doc false
  def changeset(access_log, attrs) do
    access_log
    |> cast(attrs, [
      :user_id,
      :ip_address,
      :user_agent,
      :path,
      :method,
      :country,
      :city,
      :device_type,
      :browser,
      :os
    ])
    |> validate_required([:ip_address])
  end
end
