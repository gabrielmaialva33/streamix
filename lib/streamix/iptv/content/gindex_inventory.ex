defmodule Streamix.Iptv.Content.GindexInventory do
  @moduledoc false

  import Ecto.Query, warn: false

  alias Streamix.Iptv.{Movie, Series}
  alias Streamix.Repo

  @type kind :: :movies | :series | :animes

  @doc "Returns paths already represented in the provider's durable catalog."
  @spec known_paths(pos_integer(), kind()) :: MapSet.t(String.t())
  def known_paths(provider_id, :movies) do
    Movie
    |> where([movie], movie.provider_id == ^provider_id and not is_nil(movie.gindex_path))
    |> select([movie], movie.gindex_path)
    |> Repo.all()
    |> Enum.flat_map(&movie_path_keys/1)
    |> MapSet.new()
  end

  def known_paths(provider_id, kind) when kind in [:series, :animes] do
    Series
    |> where([series], series.provider_id == ^provider_id and not is_nil(series.gindex_path))
    |> select([series], series.gindex_path)
    |> Repo.all()
    |> Enum.flat_map(&folder_path_keys/1)
    |> MapSet.new()
  end

  defp movie_path_keys(path) do
    [path | parent_directories(Path.dirname(path))]
  end

  defp parent_directories("."), do: []
  defp parent_directories("/"), do: ["/"]

  defp parent_directories(path) do
    [ensure_trailing_slash(path) | parent_directories(Path.dirname(path))]
  end

  defp folder_path_keys(path) do
    [path, ensure_trailing_slash(path)]
  end

  defp ensure_trailing_slash(path) do
    if String.ends_with?(path, "/"), do: path, else: path <> "/"
  end
end
