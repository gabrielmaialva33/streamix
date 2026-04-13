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
