defmodule Streamix.Iptv.Content.SeriesOps.Queries do
  @moduledoc """
  Compatibility facade for the focused series query modules.

  Callers keep one stable internal entrypoint while listings, details,
  episodes, and provider variants evolve independently.
  """

  alias Streamix.Iptv.Content.SeriesOps.{Details, Episodes, ListingQuery, Listings, Variants}

  defdelegate list(provider_id, opts \\ []), to: Listings
  defdelegate list_visible(user_id, opts \\ []), to: Listings
  defdelegate list_public(opts \\ []), to: Listings
  defdelegate list_public_catalog(opts \\ []), to: Listings
  defdelegate count_public_catalog(opts \\ []), to: Listings
  defdelegate count(provider_id, opts \\ []), to: Listings
  defdelegate get_by_ids(ids), to: Listings
  defdelegate list_visible_by_ids(user_id, ids, opts), to: Listings
  defdelegate list_public_by_ids(ids, opts \\ []), to: Listings
  defdelegate search(user_id, query, opts \\ []), to: Listings
  defdelegate search_public(query, opts \\ []), to: Listings

  defdelegate select_card_fields(query), to: ListingQuery

  defdelegate get_playable(user_id, series_id), to: Details
  defdelegate get_public(series_id), to: Details
  defdelegate get_with_seasons(id), to: Details
  defdelegate get_with_seasons!(id), to: Details

  defdelegate get_episode_for_stream(id), to: Episodes, as: :get_for_stream
  defdelegate get_user_episode(user_id, episode_id), to: Episodes, as: :get_for_user
  defdelegate get_playable_episode(user_id, episode_id), to: Episodes, as: :get_playable
  defdelegate get_public_episode(episode_id), to: Episodes, as: :get_public
  defdelegate get_episode_with_context!(id), to: Episodes, as: :get_with_context!
  defdelegate list_season_episodes(season_id), to: Episodes, as: :list_for_season
  defdelegate get_next_episode(episode_id), to: Episodes, as: :get_next
  defdelegate count_episodes_for_series(series_id), to: Episodes, as: :count_for_series

  defdelegate list_variants(series, user_id, opts \\ []), to: Variants, as: :list
end
