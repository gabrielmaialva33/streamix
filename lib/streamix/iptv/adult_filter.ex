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
    adult_channel_ids =
      from(lcc in "live_channel_categories",
        join: c in Category,
        on: c.id == lcc.category_id,
        where: c.provider_id == ^provider_id and c.is_adult == true,
        select: lcc.live_channel_id
      )

    from(ch in query, where: ch.id not in subquery(adult_channel_ids))
  end

  @doc """
  Filters a movie query to exclude movies in adult categories.
  """
  def exclude_adult_movies(query, provider_id) do
    adult_movie_ids =
      from(mc in "movie_categories",
        join: c in Category,
        on: c.id == mc.category_id,
        where: c.provider_id == ^provider_id and c.is_adult == true,
        select: mc.movie_id
      )

    from(m in query, where: m.id not in subquery(adult_movie_ids))
  end

  @doc """
  Filters a series query to exclude series in adult categories.
  """
  def exclude_adult_series(query, provider_id) do
    adult_series_ids =
      from(sc in "series_categories",
        join: c in Category,
        on: c.id == sc.category_id,
        where: c.provider_id == ^provider_id and c.is_adult == true,
        select: sc.series_id
      )

    from(s in query, where: s.id not in subquery(adult_series_ids))
  end

  @doc """
  Filters categories to exclude adult ones.
  """
  def exclude_adult_categories(query) do
    from(c in query, where: c.is_adult == false)
  end
end
