defmodule Streamix.Gindex.Sync.Paths do
  @moduledoc """
  Resolves configured GIndex root paths for each catalog kind.
  """

  @default_movies_path "/1:/Filmes/"
  @default_series_paths ["/1:/Séries/Séries WEB-DL/", "/1:/Séries/Séries Misturado/"]
  @default_animes_path "/0:/Animes/"

  @type source :: %{required(:drives) => [map()], optional(term()) => term()}

  @spec movies_path(source()) :: String.t()
  def movies_path(%{drives: drives}) do
    drive_path(drives, "movies", @default_movies_path)
  end

  @spec series_paths(source()) :: [String.t()]
  def series_paths(%{drives: drives}) do
    case find_drive(drives, "series") do
      %{metadata: %{"paths" => paths}} when is_list(paths) -> paths
      %{metadata: %{"path" => path}} when is_binary(path) -> [path]
      _ -> @default_series_paths
    end
  end

  @spec animes_path(source()) :: String.t()
  def animes_path(%{drives: drives}) do
    drive_path(drives, "animes", @default_animes_path)
  end

  defp drive_path(drives, drive_type, default_path) do
    case find_drive(drives, drive_type) do
      %{metadata: %{"path" => path}} -> path
      _ -> default_path
    end
  end

  defp find_drive(drives, type) when is_list(drives) do
    Enum.find(drives, &(&1.kind == type))
  end

  defp find_drive(_, _), do: nil
end
