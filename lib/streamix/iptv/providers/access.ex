defmodule Streamix.Iptv.Access do
  @moduledoc """
  Helpers for content access control queries.

  Provides reusable query builders for the three access patterns:
  - User-scoped: Only content from user's own providers
  - Playable: Content from user's providers OR public/global providers
  - Public: Content from public/global providers only (for guests)

  This module eliminates duplication across channels, movies, series, and episodes.
  """

  import Ecto.Query, warn: false

  alias Streamix.Iptv.Provider

  @doc """
  Builds a query for content owned by a specific user.
  Joins with provider and filters by user_id.

  ## Example

      LiveChannel
      |> Access.user_scoped(user_id, channel_id)
      |> Repo.one()
  """
  @spec user_scoped(Ecto.Queryable.t(), integer(), integer()) :: Ecto.Query.t()
  def user_scoped(schema, user_id, content_id) do
    schema
    |> join(:inner, [c], p in Provider, on: c.provider_id == p.id)
    |> where([c, p], c.id == ^content_id and p.user_id == ^user_id)
  end

  @doc """
  Builds a query for content playable by a user.
  Includes content from: user's providers OR public/global providers.

  ## Example

      Movie
      |> Access.playable(user_id, movie_id)
      |> preload(:provider)
      |> Repo.one()
  """
  @spec playable(Ecto.Queryable.t(), integer(), integer()) :: Ecto.Query.t()
  def playable(schema, user_id, content_id) do
    schema
    |> join(:inner, [c], p in Provider, on: c.provider_id == p.id)
    |> where([c, _p], c.id == ^content_id)
    |> where([c, p], p.visibility in [:global, :public] or p.user_id == ^user_id)
  end

  @doc """
  Builds a query for publicly accessible content.
  Only includes content from public/global providers (for guests).

  ## Example

      Series
      |> Access.public_only(series_id)
      |> preload(:provider)
      |> Repo.one()
  """
  @spec public_only(Ecto.Queryable.t(), integer()) :: Ecto.Query.t()
  def public_only(schema, content_id) do
    schema
    |> join(:inner, [c], p in Provider, on: c.provider_id == p.id)
    |> where([c, _p], c.id == ^content_id)
    |> where([c, p], p.visibility in [:global, :public])
  end

  @doc """
  Adds provider preload to a query.
  """
  @spec with_provider(Ecto.Query.t()) :: Ecto.Query.t()
  def with_provider(query) do
    preload(query, :provider)
  end

  @doc """
  Filters query to only active providers.
  """
  @spec active_only(Ecto.Query.t()) :: Ecto.Query.t()
  def active_only(query) do
    where(query, [_c, p], p.is_active == true)
  end

  @doc """
  Builds a base query for listing content from visible providers.
  Used for search and listing operations.

  ## Example

      Movie
      |> Access.visible_to_user(user_id)
      |> where([m, _p], ilike(m.name, ^"%query%"))
      |> Repo.all()
  """
  @spec visible_to_user(Ecto.Queryable.t(), integer()) :: Ecto.Query.t()
  def visible_to_user(schema, user_id) do
    schema
    |> join(:inner, [c], p in Provider, on: c.provider_id == p.id)
    |> where([c, p], p.visibility in [:global, :public] or p.user_id == ^user_id)
  end

  @doc """
  Builds a base query for listing content from public providers only.
  Used for guest search and listing operations.

  ## Example

      LiveChannel
      |> Access.public_providers()
      |> where([c, _p], ilike(c.name, ^"%query%"))
      |> Repo.all()
  """
  @spec public_providers(Ecto.Queryable.t()) :: Ecto.Query.t()
  def public_providers(schema) do
    schema
    |> join(:inner, [c], p in Provider, on: c.provider_id == p.id)
    |> where([c, p], p.visibility in [:global, :public])
  end
end
