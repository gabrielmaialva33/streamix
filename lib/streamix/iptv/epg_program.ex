defmodule Streamix.Iptv.EpgProgram do
  @moduledoc """
  Schema for EPG (Electronic Program Guide) entries.
  Stores program schedule data for live TV channels.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Streamix.Iptv.Provider

  @derive {Jason.Encoder,
           only: [
             :id,
             :epg_channel_id,
             :title,
             :description,
             :start_time,
             :end_time,
             :category,
             :icon,
             :lang,
             :provider_id
           ]}

  schema "epg_programs" do
    field :epg_channel_id, :string
    field :title, :string
    field :description, :string
    field :start_time, :utc_datetime
    field :end_time, :utc_datetime
    field :category, :string
    field :icon, :string
    field :lang, :string

    belongs_to :provider, Provider

    timestamps(type: :utc_datetime)
  end

  @required_fields ~w(epg_channel_id title start_time end_time provider_id)a
  @optional_fields ~w(description category icon lang)a

  def changeset(program, attrs) do
    program
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> unique_constraint([:provider_id, :epg_channel_id, :start_time])
    |> foreign_key_constraint(:provider_id)
  end

  @doc """
  Returns true if the program is currently airing.
  """
  def now?(%__MODULE__{start_time: start_time, end_time: end_time}) do
    now = DateTime.utc_now()

    DateTime.compare(start_time, now) in [:lt, :eq] and
      DateTime.compare(end_time, now) == :gt
  end

  def now?(_), do: false

  @doc """
  Returns progress percentage (0-100) for the program.
  """
  def progress(%__MODULE__{start_time: start_time, end_time: end_time}) do
    now = DateTime.utc_now()
    total = DateTime.diff(end_time, start_time, :second)
    elapsed = DateTime.diff(now, start_time, :second)

    if total > 0 do
      min(100, max(0, round(elapsed / total * 100)))
    else
      0
    end
  end

  def progress(_), do: 0

  @doc """
  Returns the remaining time in minutes.
  """
  def remaining_minutes(%__MODULE__{end_time: end_time}) do
    now = DateTime.utc_now()
    remaining = DateTime.diff(end_time, now, :second)
    max(0, div(remaining, 60))
  end

  def remaining_minutes(_), do: 0
end
