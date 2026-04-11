defmodule Streamix.Library.ContentRef do
  @moduledoc """
  Shared helpers for translating between external `(type, id)` library APIs
  and normalized concrete foreign-key fields.
  """

  alias Streamix.Iptv.{Episode, LiveChannel, Movie, Series}

  @favorite_types ~w(live_channel movie series episode)
  @history_types ~w(live_channel movie episode)
  @target_fields %{
    "live_channel" => :live_channel_id,
    "movie" => :movie_id,
    "series" => :series_id,
    "episode" => :episode_id
  }

  @spec favorite_types() :: [String.t()]
  def favorite_types, do: @favorite_types

  @spec history_types() :: [String.t()]
  def history_types, do: @history_types

  @spec target_field(String.t()) :: atom() | nil
  def target_field(type), do: Map.get(@target_fields, normalize_type(type))

  @spec resolve_target_attrs(String.t(), integer(), [String.t()]) ::
          {:ok, map()} | {:error, :invalid_content_type | :invalid_content_id}
  def resolve_target_attrs(type, id, allowed_types) do
    normalized_type = normalize_type(type)

    with true <- normalized_type in allowed_types,
         {:ok, normalized_id} <- normalize_id(id) do
      {:ok, %{Map.fetch!(@target_fields, normalized_type) => normalized_id}}
    else
      false -> {:error, :invalid_content_type}
      {:error, :invalid_content_id} -> {:error, :invalid_content_id}
    end
  end

  @spec content_type(struct()) :: String.t() | nil
  def content_type(%{live_channel_id: id}) when is_integer(id), do: "live_channel"
  def content_type(%{movie_id: id}) when is_integer(id), do: "movie"
  def content_type(%{series_id: id}) when is_integer(id), do: "series"
  def content_type(%{episode_id: id}) when is_integer(id), do: "episode"
  def content_type(_entry), do: nil

  @spec content_id(struct()) :: integer() | nil
  def content_id(%{live_channel_id: id}) when is_integer(id), do: id
  def content_id(%{movie_id: id}) when is_integer(id), do: id
  def content_id(%{series_id: id}) when is_integer(id), do: id
  def content_id(%{episode_id: id}) when is_integer(id), do: id
  def content_id(_entry), do: nil

  @spec content_name(struct()) :: String.t() | nil
  def content_name(%{live_channel: %LiveChannel{} = channel}), do: channel.name
  def content_name(%{movie: %Movie{} = movie}), do: movie.title || movie.name
  def content_name(%{series: %Series{} = series}), do: series.title || series.name
  def content_name(%{episode: %Episode{} = episode}), do: episode.title || episode.name
  def content_name(_entry), do: nil

  @spec content_icon(struct()) :: String.t() | nil
  def content_icon(%{live_channel: %LiveChannel{} = channel}), do: channel.stream_icon
  def content_icon(%{movie: %Movie{} = movie}), do: movie.stream_icon
  def content_icon(%{series: %Series{} = series}), do: series.cover
  def content_icon(%{episode: %Episode{} = episode}), do: episode.cover || episode.still_path
  def content_icon(_entry), do: nil

  @spec decorate(struct()) :: struct()
  def decorate(entry) do
    %{
      entry
      | content_type: content_type(entry),
        content_id: content_id(entry),
        content_name: content_name(entry),
        content_icon: content_icon(entry)
    }
  end

  defp normalize_type(type) when is_binary(type), do: type
  defp normalize_type(type) when is_atom(type), do: Atom.to_string(type)
  defp normalize_type(_type), do: nil

  defp normalize_id(id) when is_integer(id) and id > 0, do: {:ok, id}

  defp normalize_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {normalized_id, ""} when normalized_id > 0 -> {:ok, normalized_id}
      _ -> {:error, :invalid_content_id}
    end
  end

  defp normalize_id(_id), do: {:error, :invalid_content_id}
end
