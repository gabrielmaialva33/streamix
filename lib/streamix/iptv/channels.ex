defmodule Streamix.Iptv.Channels do
  @moduledoc """
  Live channel operations.

  Provides listing, searching, and retrieval of live TV channels
  with proper access control based on provider visibility.
  """

  import Ecto.Query, warn: false

  alias Streamix.Iptv.{Access, AdultFilter, LiveChannel}
  alias Streamix.Repo

  # =============================================================================
  # Listing
  # =============================================================================

  @doc """
  Lists live channels for a specific provider with optional filters.

  ## Options
    * `:limit` - Maximum number of results (default: 100)
    * `:offset` - Number of results to skip (default: 0)
    * `:search` - Search term for channel name
    * `:category_id` - Filter by category ID
    * `:show_adult` - Include adult content (default: false)
  """
  @spec list(integer(), keyword()) :: [LiveChannel.t()]
  def list(provider_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)
    offset = Keyword.get(opts, :offset, 0)
    search = Keyword.get(opts, :search)
    category_id = Keyword.get(opts, :category_id)
    show_adult = Keyword.get(opts, :show_adult, false)

    query =
      LiveChannel
      |> where(provider_id: ^provider_id)
      |> order_by(:name)

    query =
      if search && search != "" do
        where(query, [c], ilike(c.name, ^"%#{search}%"))
      else
        query
      end

    query =
      if category_id do
        join(query, :inner, [c], lcc in "live_channel_categories",
          on: lcc.live_channel_id == c.id and lcc.category_id == ^category_id
        )
      else
        query
      end

    # Filter adult content unless user opts in
    query =
      if show_adult do
        query
      else
        AdultFilter.exclude_adult_channels(query, provider_id)
      end

    query
    |> limit(^limit)
    |> offset(^offset)
    |> Repo.all()
  end

  @doc """
  Lists live channels from public/global providers for public display.
  """
  @spec list_public(keyword()) :: [LiveChannel.t()]
  def list_public(opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)

    LiveChannel
    |> Access.public_providers()
    |> where([c, _p], not is_nil(c.stream_icon))
    |> order_by([c], asc: c.name)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc """
  Counts live channels for a provider.
  """
  @spec count(integer()) :: integer()
  def count(provider_id) do
    LiveChannel
    |> where(provider_id: ^provider_id)
    |> Repo.aggregate(:count)
  end

  # =============================================================================
  # Retrieval
  # =============================================================================

  @doc """
  Gets a live channel by ID. Raises if not found.
  """
  @spec get!(integer()) :: LiveChannel.t()
  def get!(id), do: Repo.get!(LiveChannel, id)

  @doc """
  Gets a live channel by ID. Returns nil if not found.
  """
  @spec get(integer()) :: LiveChannel.t() | nil
  def get(id), do: Repo.get(LiveChannel, id)

  @doc """
  Gets a live channel owned by a specific user.
  """
  @spec get_user_channel(integer(), integer()) :: LiveChannel.t() | nil
  def get_user_channel(user_id, channel_id) do
    LiveChannel
    |> Access.user_scoped(user_id, channel_id)
    |> preload(:provider)
    |> Repo.one()
  end

  @doc """
  Gets a live channel if visible to the user (global, public, or user's private).
  Use this for player access control.
  """
  @spec get_playable(integer(), integer()) :: LiveChannel.t() | nil
  def get_playable(user_id, channel_id) do
    LiveChannel
    |> Access.playable(user_id, channel_id)
    |> preload(:provider)
    |> Repo.one()
  end

  @doc """
  Gets a live channel from public providers only (for guests).
  """
  @spec get_public(integer()) :: LiveChannel.t() | nil
  def get_public(channel_id) do
    LiveChannel
    |> Access.public_only(channel_id)
    |> preload(:provider)
    |> Repo.one()
  end

  @doc """
  Gets a live channel with preloaded provider. Raises if not found.
  """
  @spec get_with_provider!(integer()) :: LiveChannel.t()
  def get_with_provider!(id) do
    LiveChannel
    |> where(id: ^id)
    |> preload(:provider)
    |> Repo.one!()
  end

  # =============================================================================
  # Search
  # =============================================================================

  @doc """
  Searches channels across all visible providers (global + public + user's private).
  """
  @spec search(integer(), String.t(), keyword()) :: [LiveChannel.t()]
  def search(user_id, query, opts \\ []) do
    limit = Keyword.get(opts, :limit, 24)

    LiveChannel
    |> Access.visible_to_user(user_id)
    |> where([c, _p], ilike(c.name, ^"%#{query}%"))
    |> order_by([c], asc: c.name)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc """
  Searches channels in public providers only (for guests).
  """
  @spec search_public(String.t(), keyword()) :: [LiveChannel.t()]
  def search_public(query, opts \\ []) do
    limit = Keyword.get(opts, :limit, 24)

    LiveChannel
    |> Access.public_providers()
    |> where([c, _p], ilike(c.name, ^"%#{query}%"))
    |> order_by([c], asc: c.name)
    |> limit(^limit)
    |> Repo.all()
  end
end
