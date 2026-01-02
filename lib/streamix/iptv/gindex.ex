defmodule Streamix.Iptv.Gindex do
  @moduledoc """
  Public API for GIndex integration.

  Provides functions to manage GIndex providers, sync content,
  and retrieve streaming URLs.
  """

  alias Streamix.Iptv.Gindex.{Client, Parser, Sync, UrlCache}

  # Delegate sync functions
  defdelegate sync_provider(provider), to: Sync
  defdelegate sync_category(provider, category_path), to: Sync
  defdelegate list_categories(provider), to: Sync
  defdelegate list_categories(provider, movies_path), to: Sync

  # Delegate URL cache functions
  defdelegate get_movie_url(movie_id), to: UrlCache
  defdelegate invalidate_url(movie_id), to: UrlCache, as: :invalidate
  defdelegate clear_url_cache, to: UrlCache, as: :clear_all

  # Delegate parser functions
  defdelegate parse_movie_folder(folder_name), to: Parser
  defdelegate parse_release_name(filename), to: Parser
  defdelegate parse_episode_name(filename), to: Parser

  # Direct client access for advanced usage
  defdelegate list_folder(base_url, path), to: Client
  defdelegate get_download_url(base_url, file_path), to: Client
end
