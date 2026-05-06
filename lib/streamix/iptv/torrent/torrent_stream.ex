defmodule Streamix.Iptv.Torrent.TorrentStream do
  @moduledoc """
  A single magnet/info_hash known for a movie or episode.

  One movie can own N TorrentStreams — typically one per quality tier
  (480p / 720p / 1080p / 2160p) and audio variant (Dub / Dual / Sub).
  The player picks the best one at playback time by ordering on
  `seeders` desc, with the user's quality preference as a tiebreaker.

  `info_hash` is globally unique: the same release surfaces from
  multiple sources (YTS + ComandoTorrent + GratisTorrent) but the
  info_hash collapses them onto a single row. `source_slug` records
  whichever source we saw first.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Streamix.Iptv.{Episode, Movie}

  @type t :: %__MODULE__{}

  schema "torrent_streams" do
    field :info_hash, :string
    field :magnet_uri, :string

    field :quality, :string
    field :codec, :string
    field :audio_track, :string
    field :container, :string
    field :size_bytes, :integer

    field :seeders, :integer, default: 0
    field :leechers, :integer, default: 0
    field :seeders_updated_at, :utc_datetime

    field :source_slug, :string

    belongs_to :movie, Movie
    belongs_to :episode, Episode

    timestamps(type: :utc_datetime)
  end

  @fields ~w(info_hash magnet_uri quality codec audio_track container
             size_bytes seeders leechers seeders_updated_at source_slug
             movie_id episode_id)a

  @required ~w(info_hash magnet_uri source_slug)a

  def changeset(stream, attrs) do
    stream
    |> cast(attrs, @fields)
    |> validate_required(@required)
    |> update_change(:info_hash, &normalize_hash/1)
    |> validate_format(:info_hash, ~r/^[0-9a-f]{40}$/)
    |> validate_inclusion(:quality, ~w(480p 720p 1080p 2160p), message: "unknown quality")
    |> unique_constraint(:info_hash)
    |> foreign_key_constraint(:movie_id)
    |> foreign_key_constraint(:episode_id)
    |> validate_target_present()
  end

  @doc """
  Touch-only changeset for the seeders/leechers refresh worker. Keeps
  the rest of the row immutable.
  """
  def health_changeset(stream, attrs) do
    stream
    |> cast(attrs, [:seeders, :leechers, :seeders_updated_at])
    |> validate_required([:seeders_updated_at])
  end

  defp normalize_hash(nil), do: nil
  defp normalize_hash(hash) when is_binary(hash), do: String.downcase(hash)

  defp validate_target_present(changeset) do
    movie_id = get_field(changeset, :movie_id)
    episode_id = get_field(changeset, :episode_id)

    if is_nil(movie_id) and is_nil(episode_id) do
      add_error(changeset, :movie_id, "either movie_id or episode_id is required")
    else
      changeset
    end
  end
end
