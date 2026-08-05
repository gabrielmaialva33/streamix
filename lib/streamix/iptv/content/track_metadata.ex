defmodule Streamix.Iptv.Content.TrackMetadata do
  @moduledoc false

  import Ecto.Query, warn: false

  alias Streamix.Iptv.{Episode, Movie}
  alias Streamix.Repo

  @type content_type :: :movie | :episode
  @type source :: %{
          id: pos_integer(),
          gindex_path: String.t() | nil,
          track_metadata: map() | nil
        }

  @spec get_source(content_type(), pos_integer()) ::
          {:ok, source()} | {:error, :not_found | :unsupported_type}
  def get_source(:movie, id), do: load_source(Movie, id)
  def get_source(:episode, id), do: load_source(Episode, id)
  def get_source(_type, _id), do: {:error, :unsupported_type}

  @spec put(content_type(), pos_integer(), term()) ::
          :ok | {:error, :invalid_metadata | :not_found | :unsupported_type}
  def put(:movie, id, metadata) when is_map(metadata), do: update_metadata(Movie, id, metadata)

  def put(:episode, id, metadata) when is_map(metadata),
    do: update_metadata(Episode, id, metadata)

  def put(type, _id, _metadata) when type in [:movie, :episode], do: {:error, :invalid_metadata}
  def put(_type, _id, _metadata), do: {:error, :unsupported_type}

  defp load_source(schema, id) do
    query =
      from item in schema,
        where: item.id == ^id,
        select: %{
          id: item.id,
          gindex_path: item.gindex_path,
          track_metadata: item.track_metadata
        }

    case Repo.one(query) do
      nil -> {:error, :not_found}
      source -> {:ok, source}
    end
  end

  defp update_metadata(schema, id, metadata) do
    {count, _rows} =
      schema
      |> where([item], item.id == ^id)
      |> Repo.update_all(set: [track_metadata: metadata, updated_at: DateTime.utc_now(:second)])

    case count do
      1 -> :ok
      0 -> {:error, :not_found}
    end
  end
end
