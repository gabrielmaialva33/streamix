defmodule Streamix.Iptv.ChannelQuery do
  @moduledoc """
  Query builder for Channel queries.
  Centralizes filtering, pagination, and ordering logic.
  """

  import Ecto.Query, warn: false

  alias Streamix.Iptv.{Channel, Provider}

  @type filter_opts :: [
          limit: pos_integer(),
          offset: non_neg_integer(),
          group: String.t() | nil,
          search: String.t() | nil
        ]

  @default_limit 100
  @default_offset 0

  @doc """
  Builds a query for channels belonging to a specific provider.
  """
  @spec for_provider(Ecto.Queryable.t(), integer()) :: Ecto.Query.t()
  def for_provider(query \\ Channel, provider_id) do
    where(query, [c], c.provider_id == ^provider_id)
  end

  @doc """
  Builds a query for channels belonging to a user's active providers.
  """
  @spec for_user(Ecto.Queryable.t(), integer()) :: Ecto.Query.t()
  def for_user(query \\ Channel, user_id) do
    query
    |> join(:inner, [c], p in Provider, on: c.provider_id == p.id)
    |> where([c, p], p.user_id == ^user_id and p.is_active == true)
  end

  @doc """
  Applies standard filters to a channel query.

  ## Options
    * `:limit` - Maximum number of results (default: 100)
    * `:offset` - Number of results to skip (default: 0)
    * `:group` - Filter by group_title
    * `:search` - Search by channel name (case-insensitive)
  """
  @spec apply_filters(Ecto.Query.t(), filter_opts()) :: Ecto.Query.t()
  def apply_filters(query, opts \\ []) do
    query
    |> filter_by_group(Keyword.get(opts, :group))
    |> filter_by_search(Keyword.get(opts, :search))
    |> apply_ordering()
    |> apply_pagination(opts)
  end

  @doc """
  Applies only pagination and ordering without other filters.
  Useful when filters are already applied.
  """
  @spec paginate(Ecto.Query.t(), filter_opts()) :: Ecto.Query.t()
  def paginate(query, opts \\ []) do
    query
    |> apply_ordering()
    |> apply_pagination(opts)
  end

  @doc """
  Returns a query for distinct group titles.
  """
  @spec distinct_groups(Ecto.Query.t()) :: Ecto.Query.t()
  def distinct_groups(query) do
    query
    |> select([c], c.group_title)
    |> where([c], not is_nil(c.group_title))
    |> distinct(true)
    |> order_by([c], asc: c.group_title)
  end

  # Private functions

  defp filter_by_group(query, nil), do: query
  defp filter_by_group(query, ""), do: query

  defp filter_by_group(query, group) do
    where(query, [c], c.group_title == ^group)
  end

  defp filter_by_search(query, nil), do: query
  defp filter_by_search(query, ""), do: query

  defp filter_by_search(query, search) do
    search_term = "%#{sanitize_search(search)}%"
    where(query, [c], ilike(c.name, ^search_term))
  end

  defp sanitize_search(search) do
    search
    |> String.replace(~r/[%_\\]/, fn
      "%" -> "\\%"
      "_" -> "\\_"
      "\\" -> "\\\\"
    end)
  end

  defp apply_ordering(query) do
    order_by(query, [c], asc: c.group_title, asc: c.name)
  end

  defp apply_pagination(query, opts) do
    limit = Keyword.get(opts, :limit, @default_limit)
    offset = Keyword.get(opts, :offset, @default_offset)

    query
    |> limit(^limit)
    |> offset(^offset)
  end
end
