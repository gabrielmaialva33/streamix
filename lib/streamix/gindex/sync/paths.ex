defmodule Streamix.Gindex.Sync.Paths do
  @moduledoc """
  Resolves configured GIndex root paths for each catalog kind.
  """

  alias Streamix.Iptv.{Provider, Providers}

  @default_movies_path "/1:/Filmes/"
  @default_series_paths ["/1:/Séries/Séries WEB-DL/", "/1:/Séries/Séries Misturado/"]
  @default_animes_path "/0:/Animes/"

  @spec movies_path(Provider.t()) :: String.t()
  def movies_path(%Provider{} = provider) do
    provider
    |> preload_drives()
    |> drive_path("movies", @default_movies_path)
  end

  @spec series_paths(Provider.t()) :: [String.t()]
  def series_paths(%Provider{} = provider) do
    provider = preload_drives(provider)

    case find_drive(provider.drives, "series") do
      %{metadata: %{"paths" => paths}} when is_list(paths) -> paths
      %{metadata: %{"path" => path}} when is_binary(path) -> [path]
      _ -> @default_series_paths
    end
  end

  @spec animes_path(Provider.t()) :: String.t()
  def animes_path(%Provider{} = provider) do
    provider
    |> preload_drives()
    |> drive_path("animes", @default_animes_path)
  end

  defp preload_drives(provider), do: Providers.preload_drives(provider)

  defp drive_path(provider, drive_type, default_path) do
    case find_drive(provider.drives, drive_type) do
      %{metadata: %{"path" => path}} -> path
      _ -> default_path
    end
  end

  defp find_drive(drives, type) when is_list(drives) do
    Enum.find(drives, &(&1.drive_type == type))
  end

  defp find_drive(_, _), do: nil
end
