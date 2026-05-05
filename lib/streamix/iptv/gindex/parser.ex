defmodule Streamix.Iptv.Gindex.Parser do
  @moduledoc """
  Public facade for GIndex file and folder name parsing.

  The focused parser modules live under `Streamix.Iptv.Gindex.Parser.*`; keep
  this module as the stable API used by scrapers, sync code, and tests.
  """

  alias Streamix.Iptv.Gindex.Parser.{AnimeEpisode, Files, Folders, ReleaseFolder, ReleaseName}

  defdelegate parse_movie_folder(folder_name), to: Folders
  defdelegate parse_series_folder(folder_name), to: Folders
  defdelegate parse_anime_folder(folder_name), to: Folders
  defdelegate parse_season_folder(folder_name), to: Folders

  defdelegate parse_anime_episode(filename), to: AnimeEpisode, as: :parse
  defdelegate parse_release_folder(folder_name), to: ReleaseFolder, as: :parse
  defdelegate parse_release_name(filename), to: ReleaseName
  defdelegate parse_episode_name(filename), to: ReleaseName

  defdelegate video_file?(filename), to: Files
  defdelegate split_extension(filename), to: Files
  defdelegate path_to_stream_id(path), to: Files
  defdelegate parse_file_size(size_str), to: Files
end
