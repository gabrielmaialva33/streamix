defmodule Streamix.Iptv.Channels do
  @moduledoc """
  Live channel operations.

  Provides listing, searching, and retrieval of live TV channels
  with proper access control based on provider visibility.
  """

  import Ecto.Query, warn: false

  alias Streamix.Helpers
  alias Streamix.Iptv.{Access, AdultFilter, EpgChannel, EpgProgram, LiveChannel, RankedSearch}
  alias Streamix.Repo

  # How long a channel stays hidden after a 404 before we let it back in
  # for another playback attempt. Auto-healing: if the upstream recovers
  # the channel reappears without manual intervention.
  @dead_recheck_hours 24

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

    provider_id
    |> build_query(opts)
    |> order_by(:name)
    |> limit(^limit)
    |> offset(^offset)
    |> Repo.all()
  end

  @doc """
  Lists live channels across all Xtream providers visible to a user.
  """
  @spec list_visible(integer(), keyword()) :: [LiveChannel.t()]
  def list_visible(user_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)
    offset = Keyword.get(opts, :offset, 0)

    user_id
    |> build_visible_query(opts)
    |> order_by([c], asc: c.name)
    |> limit(^limit)
    |> offset(^offset)
    |> Repo.all()
  end

  # Shared filter pipeline for list/2 and count/2. Keeping both paths behind
  # this single builder is the only way to guarantee that `total` and the
  # items returned in `list` stay in sync — the previous implementation had
  # the count bypass `category_id` / `search`, so `has_more` reported `true`
  # on the final page of filtered results. Do not inline these filters at
  # the call site.
  defp build_query(provider_id, opts) do
    search = Keyword.get(opts, :search)
    category_id = Keyword.get(opts, :category_id)
    show_adult = Keyword.get(opts, :show_adult, false)

    query =
      LiveChannel
      |> where(provider_id: ^provider_id)
      |> exclude_dead()

    query =
      if search && search != "" do
        escaped = Helpers.escape_like(search)
        where(query, [c], ilike(c.name, ^"%#{escaped}%"))
      else
        query
      end

    query =
      if category_id do
        join(query, :inner, [c], ic in "item_categories",
          on: ic.catalog_item_id == c.catalog_item_id and ic.category_id == ^category_id
        )
      else
        query
      end

    if show_adult do
      query
    else
      AdultFilter.exclude_adult_channels(query, provider_id)
    end
  end

  defp build_visible_query(user_id, opts) do
    search = Keyword.get(opts, :search)
    show_adult = Keyword.get(opts, :show_adult, false)

    query =
      LiveChannel
      |> Access.visible_to_user(user_id)
      |> where([_c, p], p.provider_type == :xtream and p.is_active == true)
      |> exclude_dead()

    query =
      if search && search != "" do
        escaped = Helpers.escape_like(search)
        where(query, [c], ilike(c.name, ^"%#{escaped}%"))
      else
        query
      end

    if show_adult do
      query
    else
      AdultFilter.exclude_adult_content(query)
    end
  end

  @doc """
  Lists live channels with current EPG program in a single query.
  More efficient than list/2 + enrich_channels_with_epg for high-traffic pages.

  Returns channels with a virtual :current_program field containing the EPG data.

  ## Options
    Same as `list/2` plus:
    * `:with_epg` - Include EPG data (default: true)
  """
  @spec list_with_epg(integer(), keyword()) :: [map()]
  def list_with_epg(provider_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)
    offset = Keyword.get(opts, :offset, 0)
    search = Keyword.get(opts, :search)
    category_id = Keyword.get(opts, :category_id)
    show_adult = Keyword.get(opts, :show_adult, false)

    now = DateTime.utc_now()

    # Build base query with LEFT JOIN to EPG via epg_channels
    query =
      from c in LiveChannel,
        left_lateral_join:
          epg in subquery(
            from p in EpgProgram,
              join: ec in EpgChannel,
              on: p.epg_channel_id == ec.id,
              where:
                ec.provider_id == parent_as(:channel).provider_id and
                  ec.external_id == parent_as(:channel).epg_channel_id and
                  p.start_time <= ^now and
                  p.end_time > ^now,
              select: p,
              limit: 1
          ),
        as: :channel,
        on: true,
        where: c.provider_id == ^provider_id,
        order_by: c.name,
        select: %{
          channel: c,
          current_program: epg
        }

    query = exclude_dead(query)

    query =
      if search && search != "" do
        escaped = Helpers.escape_like(search)
        where(query, [c], ilike(c.name, ^"%#{escaped}%"))
      else
        query
      end

    query =
      if category_id do
        join(query, :inner, [c], ic in "item_categories",
          on: ic.catalog_item_id == c.catalog_item_id and ic.category_id == ^category_id
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
    |> Enum.map(fn %{channel: channel, current_program: epg} ->
      Map.put(channel, :current_program, epg)
    end)
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
    |> exclude_dead()
    |> order_by([c], asc: c.name)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc """
  Marks a channel as dead because the upstream returned a terminal error
  (typically 404) during a resolve attempt. Called by the stream proxy.

  Null-safe: if the channel id is unknown or the row is gone, this is a no-op.
  """
  @spec mark_dead(integer() | nil) :: :ok
  def mark_dead(nil), do: :ok

  def mark_dead(channel_id) when is_integer(channel_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {_count, _} =
      LiveChannel
      |> where(id: ^channel_id)
      |> Repo.update_all(set: [dead_since: now, updated_at: now])

    :ok
  end

  @doc """
  Clears the dead flag for a channel (called implicitly by sync when the
  upstream lists the channel again, or after a successful resolve).
  """
  @spec mark_alive(integer()) :: :ok
  def mark_alive(channel_id) when is_integer(channel_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {_count, _} =
      LiveChannel
      |> where(id: ^channel_id)
      |> where([c], not is_nil(c.dead_since))
      |> Repo.update_all(set: [dead_since: nil, updated_at: now])

    :ok
  end

  # Filters out channels marked dead within the recheck window. After the
  # window expires they reappear for another playback attempt (auto-healing).
  defp exclude_dead(query) do
    cutoff =
      DateTime.utc_now()
      |> DateTime.add(-@dead_recheck_hours * 3600, :second)
      |> DateTime.truncate(:second)

    where(query, [c], is_nil(c.dead_since) or c.dead_since < ^cutoff)
  end

  @doc """
  Counts live channels visible to public listings for a provider.

  Mirrors the filters applied by `list/2` / `list_with_epg/2`:
    * excludes channels marked dead within the recheck window
    * excludes adult channels unless `:show_adult` is true

  Without this mirroring, `has_more` in paginated API responses would
  remain `true` on the final page (total counted dead rows that the
  list never returns).
  """
  @spec count(integer(), keyword()) :: integer()
  def count(provider_id, opts \\ []) do
    provider_id
    |> build_query(opts)
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
  Gets a live channel for stream resolution with only the provider preloaded.
  """
  @spec get_for_stream(integer()) :: LiveChannel.t() | nil
  def get_for_stream(id) do
    LiveChannel
    |> where(id: ^id)
    |> preload(:provider)
    |> Repo.one()
  end

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
    escaped = Helpers.escape_like(query)

    LiveChannel
    |> Access.visible_to_user(user_id)
    |> where([c, _p], ilike(c.name, ^"%#{escaped}%"))
    |> order_by([c], asc: c.name)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc """
  Searches channels in public providers only (for guests).

  Uses `Streamix.Iptv.RankedSearch` for fuzzy + ranked matching.
  Channels don't carry ratings, so `rating_field: false` disables the
  secondary sort key.
  """
  @spec search_public(String.t(), keyword()) :: [LiveChannel.t()]
  def search_public(query, opts \\ []) do
    limit = Keyword.get(opts, :limit, 24)

    LiveChannel
    |> Access.public_providers()
    |> RankedSearch.build([:name], query, limit: limit, rating_field: false)
    |> Repo.all()
  end
end
