defmodule Streamix.Iptv.Content.SeriesOps.Reels do
  @moduledoc """
  Vertical short dramas ("Reels") offered by Xtream providers.

  Providers ingest short dramas as ordinary series. The only marker is a
  provider category whose name starts with `[Reels] `, for example
  `[Reels] Histórias da Ásia`. Categories belong to one provider, so this
  module merges them by display name (the name without the prefix) across
  every provider the viewer may browse.

  Listings reuse the series browse rules: provider visibility, the
  `browsable` operator/health switches, the adult-content exclusion and the
  canonical variant collapse, so a drama synchronized by two providers is
  listed once. Reel membership is a semi-join over `item_categories` driven
  by the literal prefix predicate `name LIKE '[Reels] %'`, which the
  `categories_name_trgm_idx` trigram index can answer.
  """

  import Ecto.Query, warn: false

  alias Streamix.Iptv.Category
  alias Streamix.Iptv.Content.SeriesOps.ListingQuery
  alias Streamix.Iptv.Series
  alias Streamix.Repo

  @default_limit 48
  @max_limit 100
  @max_offset 100_000
  # categories.name is varchar(255); a display name drops the "[Reels] "
  # prefix, so it can be up to 247 characters long.
  @max_category_length 247
  @sort "created_desc"
  @visible_preloads [:genres]
  @public_preloads [:provider, :genres]

  # Display name: the category name after the 8-character `[Reels] ` prefix.
  defmacrop reel_display_name(name) do
    quote do: fragment("btrim(substr(?, 9))", unquote(name))
  end

  @typedoc "One reel category merged across providers."
  @type category_summary :: %{name: String.t(), count: non_neg_integer()}

  @doc """
  Lists reel series visible to `user_id`, newest first.

  ## Options
    * `:category` - reel category display name (without the `[Reels] ` prefix)
    * `:show_adult` - include adult content (default: `false`)
    * `:limit` - page size (default: #{@default_limit}, at most #{@max_limit})
    * `:offset` - canonical rows to skip (default: 0)

  Each returned series carries its reel category display name in
  `:reel_category`.
  """
  @spec list_visible(integer() | nil, keyword()) :: [Series.t()]
  def list_visible(user_id, opts \\ []) do
    user_id
    |> ListingQuery.filtered_visible(show_adult: Keyword.get(opts, :show_adult, false))
    |> list_page(opts, @visible_preloads)
  end

  @doc """
  Lists reel display categories visible to `user_id` with the number of
  canonical series in each, largest first. Accepts `:show_adult`.
  """
  @spec list_visible_categories(integer() | nil, keyword()) :: [category_summary()]
  def list_visible_categories(user_id, opts \\ []) do
    user_id
    |> ListingQuery.filtered_visible(show_adult: Keyword.get(opts, :show_adult, false))
    |> category_counts()
  end

  @doc """
  Lists reel series from public/global providers, newest first.

  Accepts the same options as `list_visible/2`; adult content is excluded
  unless `:show_adult` is `true`. Each series has its provider preloaded.
  """
  @spec list_public(keyword()) :: [Series.t()]
  def list_public(opts \\ []) do
    opts
    |> public_scope()
    |> list_page(opts, @public_preloads)
  end

  @doc "Counts the canonical series returned by `list_public/1` across all pages."
  @spec count_public(keyword()) :: non_neg_integer()
  def count_public(opts \\ []) do
    opts
    |> public_scope()
    |> reels_only(category_option(opts))
    |> ListingQuery.count_variants()
    |> Repo.one()
  end

  @doc "Lists reel display categories from public/global providers with counts."
  @spec list_public_categories(keyword()) :: [category_summary()]
  def list_public_categories(opts \\ []) do
    opts
    |> public_scope()
    |> category_counts()
  end

  defp public_scope(opts) do
    ListingQuery.filtered_public(show_adult: Keyword.get(opts, :show_adult, false))
  end

  defp list_page(scope, opts, preloads) do
    category = category_option(opts)
    limit = bounded(Keyword.get(opts, :limit), @default_limit, 1, @max_limit)
    offset = bounded(Keyword.get(opts, :offset), 0, 0, @max_offset)

    scope
    |> reels_only(category)
    |> ListingQuery.variant_page(@sort, limit, offset)
    |> ListingQuery.select_card_fields()
    |> preload(^preloads)
    |> Repo.all()
    |> put_reel_categories(category)
  end

  # Semi-join on the catalog items tagged with a reel category. A named
  # category narrows the same subquery instead of adding a second join.
  defp reels_only(query, category) do
    reel_items =
      reel_item_categories()
      |> where_display_name(category)
      |> select([item_category], item_category.catalog_item_id)

    where(query, [series], series.catalog_item_id in subquery(reel_items))
  end

  defp where_display_name(query, nil), do: query

  defp where_display_name(query, name) do
    where(query, [_item_category, category], reel_display_name(category.name) == ^name)
  end

  defp category_counts(scope) do
    reels =
      select(reel_item_categories(), [item_category, category], %{
        catalog_item_id: item_category.catalog_item_id,
        name: reel_display_name(category.name)
      })

    scope
    |> join(:inner, [series], reel in subquery(reels),
      on: reel.catalog_item_id == series.catalog_item_id
    )
    |> group_by([..., reel], reel.name)
    |> select([series, ..., reel], %{
      name: selected_as(reel.name, :name),
      count: selected_as(count(series.variant_key, :distinct), :count)
    })
    |> order_by([], desc: selected_as(:count), asc: selected_as(:name))
    |> Repo.all()
  end

  defp put_reel_categories([], _category), do: []

  defp put_reel_categories(series, category) when is_binary(category) do
    Enum.map(series, &%{&1 | reel_category: category})
  end

  # Without a filter a title may sit in several reel categories (for example
  # "Lançamentos" and a genre); one batched query picks a stable label.
  defp put_reel_categories(series, nil) do
    catalog_item_ids = Enum.map(series, & &1.catalog_item_id)

    labels =
      reel_item_categories()
      |> where([item_category], item_category.catalog_item_id in ^catalog_item_ids)
      |> group_by([item_category], item_category.catalog_item_id)
      |> select([item_category, category], {
        item_category.catalog_item_id,
        min(reel_display_name(category.name))
      })
      |> Repo.all()
      |> Map.new()

    Enum.map(series, &%{&1 | reel_category: Map.get(labels, &1.catalog_item_id)})
  end

  # Catalog items tagged with a named reel category. The prefix stays a SQL
  # literal so the planner can use the trigram index on `categories.name`.
  defp reel_item_categories do
    from(item_category in "item_categories",
      join: category in Category,
      on: category.id == item_category.category_id,
      where:
        category.type == "series" and fragment("? LIKE '[Reels] %'", category.name) and
          reel_display_name(category.name) != ""
    )
  end

  defp category_option(opts) do
    case Keyword.get(opts, :category) do
      name when is_binary(name) ->
        name
        |> String.trim()
        |> String.slice(0, @max_category_length)
        |> blank_to_nil()

      _other ->
        nil
    end
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp bounded(value, _default, minimum, maximum) when is_integer(value),
    do: value |> max(minimum) |> min(maximum)

  defp bounded(_value, default, _minimum, _maximum), do: default
end
