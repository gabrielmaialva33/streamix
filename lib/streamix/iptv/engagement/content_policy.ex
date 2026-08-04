defmodule Streamix.Iptv.Engagement.ContentPolicy do
  @moduledoc false

  import Ecto.Query, warn: false

  alias Streamix.Iptv.CatalogItem
  alias Streamix.Repo

  @doc """
  Applies the authoritative provider visibility policy to a query containing
  a named `:catalog_item` binding.

  Missing content rows and inactive providers fail closed. `catalog_items`
  carries the provider boundary for every supported content type, including
  episodes.
  """
  @spec visible_to_user(Ecto.Queryable.t(), integer()) :: Ecto.Query.t()
  def visible_to_user(query, user_id) do
    where(
      query,
      [catalog_item: catalog_item],
      fragment(
        """
        EXISTS (
          SELECT 1
          FROM providers AS policy_provider
          WHERE policy_provider.id = ?
          AND policy_provider.is_active = TRUE
          AND (
            policy_provider.visibility IN ('global', 'public')
            OR policy_provider.user_id = ?
          )
        )
        """,
        catalog_item.provider_id,
        ^user_id
      )
    )
  end

  @doc """
  Excludes adult catalog items. For episodes, the parent series categories are
  checked as well because Xtream providers normally classify the series, not
  each episode.
  """
  @spec exclude_adult(Ecto.Queryable.t()) :: Ecto.Query.t()
  def exclude_adult(query) do
    where(
      query,
      [catalog_item: catalog_item],
      fragment(
        """
        NOT EXISTS (
          SELECT 1
          FROM item_categories AS policy_item_category
          JOIN categories AS policy_category
            ON policy_category.id = policy_item_category.category_id
          WHERE policy_item_category.catalog_item_id = ?
            AND policy_category.is_adult = TRUE
        )
        AND (
          ? <> 'episode'
          OR NOT EXISTS (
            SELECT 1
            FROM episodes AS policy_episode
            JOIN seasons AS policy_season ON policy_season.id = policy_episode.season_id
            JOIN series AS policy_series ON policy_series.id = policy_season.series_id
            JOIN item_categories AS policy_series_category
              ON policy_series_category.catalog_item_id = policy_series.catalog_item_id
            JOIN categories AS policy_category
              ON policy_category.id = policy_series_category.category_id
            WHERE policy_episode.catalog_item_id = ?
              AND policy_category.is_adult = TRUE
          )
        )
        """,
        catalog_item.id,
        catalog_item.content_type,
        catalog_item.id
      )
    )
  end

  @spec visible_catalog_item?(integer(), integer()) :: boolean()
  def visible_catalog_item?(user_id, catalog_item_id) do
    CatalogItem
    |> from(as: :catalog_item)
    |> where([catalog_item: catalog_item], catalog_item.id == ^catalog_item_id)
    |> visible_to_user(user_id)
    |> Repo.exists?()
  end
end
