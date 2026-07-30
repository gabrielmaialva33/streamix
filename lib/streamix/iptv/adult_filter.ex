defmodule Streamix.Iptv.AdultFilter do
  @moduledoc """
  Query helpers for filtering adult content based on user preferences.
  Filters content that belongs to categories marked as adult.
  """

  import Ecto.Query, warn: false

  alias Streamix.Iptv.Category

  @doc """
  Filters a live channel query to exclude channels in adult categories.
  """
  def exclude_adult_channels(query, provider_id) do
    adult_ci_ids =
      from(ic in "item_categories",
        join: c in Category,
        on: c.id == ic.category_id,
        where: c.provider_id == ^provider_id and c.is_adult == true,
        select: ic.catalog_item_id
      )

    from(ch in query, where: ch.catalog_item_id not in subquery(adult_ci_ids))
  end

  @doc """
  Filters a catalog-item backed query to exclude content in any adult category.

  Use this for aggregate queries that span multiple providers; provider-scoped
  helpers above are cheaper when the query already targets one provider.
  """
  def exclude_adult_content(query) do
    adult_content =
      from(ic in "item_categories",
        join: c in Category,
        on: c.id == ic.category_id,
        where:
          ic.catalog_item_id == parent_as(:adult_filter_item).catalog_item_id and
            c.is_adult == true,
        select: 1
      )

    from(item in query,
      as: :adult_filter_item,
      where: not exists(subquery(adult_content))
    )
  end

  @doc """
  Filters a movie query to exclude movies in adult categories.
  """
  def exclude_adult_movies(query, provider_id) do
    adult_ci_ids =
      from(ic in "item_categories",
        join: c in Category,
        on: c.id == ic.category_id,
        where: c.provider_id == ^provider_id and c.is_adult == true,
        select: ic.catalog_item_id
      )

    from(m in query, where: m.catalog_item_id not in subquery(adult_ci_ids))
  end

  @doc """
  Filters a series query to exclude series in adult categories.
  """
  def exclude_adult_series(query, provider_id) do
    adult_ci_ids =
      from(ic in "item_categories",
        join: c in Category,
        on: c.id == ic.category_id,
        where: c.provider_id == ^provider_id and c.is_adult == true,
        select: ic.catalog_item_id
      )

    from(s in query, where: s.catalog_item_id not in subquery(adult_ci_ids))
  end

  @doc """
  Filters categories to exclude adult ones.
  """
  def exclude_adult_categories(query) do
    from(c in query, where: c.is_adult == false)
  end
end
