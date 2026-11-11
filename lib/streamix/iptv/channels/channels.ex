defmodule Streamix.Iptv.Channels do
  @moduledoc """
  Live channel operations.

  Provides listing, searching, and retrieval of live TV channels
  with proper access control based on provider visibility.
  """

  import Ecto.Query, warn: false

  alias Streamix.Helpers

  alias Streamix.Iptv.{
    Access,
    AdultFilter,
    Category,
    EpgChannel,
    EpgProgram,
    LiveChannel,
    RankedSearch,
    Series
  }

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
    |> by_display_name()
    |> limit(^limit)
    |> offset(^offset)
    |> Repo.all()
  end

  @doc """
  Lists live channels across all Xtream providers visible to a user.

  Takes `:limit`, `:offset`, `:search`, `:provider_id`, `:show_adult` and
  `:airing_between` (`{starts_at, ends_at}`: only channels whose guide has a
  program in that window).
  """
  @spec list_visible(integer(), keyword()) :: [LiveChannel.t()]
  def list_visible(user_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)
    offset = Keyword.get(opts, :offset, 0)

    user_id
    |> build_visible_query(opts)
    |> by_display_name()
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

  @doc false
  def visible_query(user_id, opts), do: build_visible_query(user_id, opts)

  # "24H | Séries", "24HRS I SHOWS", "24HRS ✝️ Caminho da Fé": providers'
  # own around-the-clock channels, filed under a 24h category.
  @round_the_clock_category ~r/^\W*24\s*(?:h|hrs|horas)\b/iu
  @round_the_clock_prefix ~r/^\W*24\s*(?:hrs|horas|h)\b[\s|I:\-–\p{So}\x{FE0F}]*/iu
  @round_the_clock_labels %{
    "series" => "Séries",
    "desenhos" => "Desenhos",
    "filmes" => "Filmes",
    "documentarios" => "Documentários",
    "shows" => "Shows",
    "caminho da fe" => "Fé"
  }

  @doc """
  The providers' own 24h live channels a user may watch ("24H | Séries",
  "24HRS I SHOWS"...), grouped under one label per kind across providers,
  largest group first. Each channel carries `:logo` (its own, never a
  placeholder shared by many) and `:poster` (the cover of the catalog series
  it is named after), either of which may be nil. Adult categories and dead channels are left out
  (adult unless `show_adult: true`); a name repeated across providers is
  listed once, as its oldest channel.
  """
  @spec list_round_the_clock(integer() | nil, keyword()) :: [
          %{label: String.t(), channels: [map()]}
        ]
  def list_round_the_clock(user_id, opts \\ []) do
    show_adult = Keyword.get(opts, :show_adult, false)

    user_id
    |> build_visible_query(show_adult: show_adult)
    |> join(:inner, [c, _p], ic in "item_categories", on: ic.catalog_item_id == c.catalog_item_id)
    |> join(:inner, [_c, _p, ic], k in Category, on: k.id == ic.category_id)
    |> where(
      [_c, _p, _ic, k],
      k.type == "live" and fragment("? ~* ?", k.name, "^\\W*24\\s*(h|hrs|horas)\\M")
    )
    |> where([_c, _p, _ic, k], ^show_adult or not k.is_adult)
    |> select([c, _p, _ic, k], %{
      id: c.id,
      name: c.name,
      stream_icon: c.stream_icon,
      category: k.name
    })
    |> Repo.all()
    |> Enum.filter(&Regex.match?(@round_the_clock_category, &1.category))
    |> with_artwork()
    |> Enum.group_by(&round_the_clock_label(&1.category))
    |> Enum.map(fn {label, channels} ->
      %{
        label: label,
        channels:
          channels
          |> Enum.sort_by(& &1.id)
          |> Enum.uniq_by(&(&1.name |> String.trim() |> String.downcase()))
          |> Enum.sort_by(&String.downcase(&1.name))
          |> Enum.map(&Map.delete(&1, :category))
      }
    end)
    |> Enum.sort_by(&{-length(&1.channels), &1.label})
  end

  # A provider often gives every 24h channel the same placeholder logo. A
  # logo shared by this many channels says nothing and is dropped; a
  # channel named after a series in the catalog ("Chaves 02", "Dois Homens e
  # Meio (Parte 1)") shows that series' poster instead.
  @placeholder_logo_threshold 3

  defp with_artwork(channels) do
    shared =
      channels
      |> Enum.map(& &1.stream_icon)
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.frequencies()
      |> Enum.flat_map(fn {icon, n} ->
        if n >= @placeholder_logo_threshold, do: [icon], else: []
      end)
      |> MapSet.new()

    posters = series_posters(Enum.map(channels, &series_key(&1.name)))

    Enum.map(channels, fn channel ->
      logo =
        if channel.stream_icon in [nil, ""] or channel.stream_icon in shared,
          do: nil,
          else: channel.stream_icon

      channel
      |> Map.delete(:stream_icon)
      |> Map.merge(%{logo: logo, poster: Map.get(posters, series_key(channel.name))})
    end)
  end

  # An exact title first; for a name left unmatched, the best-rated series
  # whose title starts with it ("Chapolin" → "Chapolin Colorado").
  defp series_posters(keys) do
    keys = keys |> Enum.reject(&(String.length(&1) < 3)) |> Enum.uniq()
    exact = covers(keys, :exact)
    missing = Enum.reject(keys, &Map.has_key?(exact, &1))

    by_prefix =
      missing
      |> covers(:prefix)
      |> Enum.flat_map(fn {title, cover} ->
        for key <- missing, String.starts_with?(title, key <> " "), do: {key, cover}
      end)
      |> Enum.reverse()
      |> Map.new()

    Map.merge(by_prefix, exact)
  end

  defp covers([], _match), do: %{}

  defp covers(keys, match) do
    patterns = Enum.map(keys, &(Helpers.escape_like(&1) <> " %"))

    base =
      from(s in Series,
        where: not is_nil(s.cover) and s.cover != "",
        order_by: [desc: s.rating],
        select: {fragment("lower(coalesce(?, ?))", s.title, s.name), s.cover}
      )

    query =
      case match do
        :exact ->
          where(base, [s], fragment("lower(coalesce(?, ?))", s.title, s.name) in ^keys)

        :prefix ->
          where(
            base,
            [s],
            fragment("lower(coalesce(?, ?)) LIKE ANY(?)", s.title, s.name, ^patterns)
          )
      end

    query |> Repo.all() |> Enum.reverse() |> Map.new()
  end

  @doc false
  # "Chaves 02", "Dois Homens e Meio (Parte 1)", "Bob Esponja Part 01",
  # "Big Bang: A Teoria 2" → the series' own name, lowercased.
  def series_key(name) do
    name
    |> String.replace(~r/\s*[-–]?\s*\(?\s*part[e]?\s*\d+\s*\)?\s*$/iu, "")
    |> String.replace(~r/\s+\d{1,2}$/u, "")
    |> String.trim()
    |> String.downcase()
  end

  @doc false
  def round_the_clock_label(category) do
    rest = category |> String.replace(@round_the_clock_prefix, "") |> String.trim()
    key = rest |> String.normalize(:nfd) |> String.replace(~r/\p{M}/u, "") |> String.downcase()

    Map.get_lazy(@round_the_clock_labels, key, fn ->
      if rest == "", do: "Outros", else: rest |> String.downcase() |> String.capitalize()
    end)
  end

  defp build_visible_query(user_id, opts) do
    LiveChannel
    |> Access.visible_to_user(user_id)
    |> where([_channel, provider], provider.provider_type == :xtream)
    |> build_aggregate_query(opts)
  end

  defp build_public_query(opts) do
    LiveChannel
    |> Access.public_providers()
    |> where([_channel, provider], provider.provider_type == :xtream)
    |> build_aggregate_query(opts)
  end

  defp build_aggregate_query(query, opts) do
    search = Keyword.get(opts, :search)
    category_id = Keyword.get(opts, :category_id)
    show_adult = Keyword.get(opts, :show_adult, false)

    query =
      query
      |> maybe_where_provider(Keyword.get(opts, :provider_id))
      |> maybe_where_provider_type(Keyword.get(opts, :provider_type))
      |> maybe_airing_between(Keyword.get(opts, :airing_between))
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
        join(query, :inner, [c, _p], ic in "item_categories",
          on: ic.catalog_item_id == c.catalog_item_id and ic.category_id == ^category_id
        )
      else
        query
      end

    if show_adult do
      query
    else
      AdultFilter.exclude_adult_content(query)
    end
  end

  # By name, with the provider's placeholder and one-off event channels
  # ("(01)", "[PPV] 03", "21:30 • Atlanta Hawks x...") after the named ones, so
  # a list opens on real channels.
  defp by_display_name(query) do
    order_by(query, [c],
      asc: fragment("? ~ '^\\s*([(\\[#]|\\d{1,2}[:h]\\d{2})'", c.name),
      asc: c.name
    )
  end

  # `airing_between: {starts_at, ends_at}` keeps the channels whose guide
  # has a program overlapping that window (what a TV guide can show).
  defp maybe_airing_between(query, nil), do: query

  defp maybe_airing_between(query, {%DateTime{} = starts_at, %DateTime{} = ends_at}) do
    starts_at = DateTime.to_naive(starts_at)
    ends_at = DateTime.to_naive(ends_at)

    where(
      query,
      [c],
      not is_nil(c.epg_channel_id) and
        fragment(
          "EXISTS (SELECT 1 FROM epg_channels e JOIN epg_programs p ON p.epg_channel_id = e.id WHERE e.provider_id = ? AND e.external_id = ? AND p.end_time > ? AND p.start_time < ?)",
          c.provider_id,
          c.epg_channel_id,
          ^starts_at,
          ^ends_at
        )
    )
  end

  defp maybe_where_provider(query, nil), do: query

  defp maybe_where_provider(query, provider_id),
    do: where(query, [_channel, provider], provider.id == ^provider_id)

  defp maybe_where_provider_type(query, nil), do: query

  defp maybe_where_provider_type(query, provider_type),
    do: where(query, [_channel, provider], provider.provider_type == ^provider_type)

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
    show_adult = Keyword.get(opts, :show_adult, false)

    LiveChannel
    |> Access.public_providers()
    |> maybe_exclude_adult(show_adult)
    |> where([c, _p], not is_nil(c.stream_icon))
    |> exclude_dead()
    |> by_display_name()
    |> limit(^limit)
    |> preload(:provider)
    |> Repo.all()
  end

  @doc "Lists live channels across public/global Xtream providers."
  @spec list_public_catalog(keyword()) :: [LiveChannel.t()]
  def list_public_catalog(opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)
    offset = Keyword.get(opts, :offset, 0)

    opts
    |> build_public_query()
    |> order_by([channel], asc: channel.name, desc: channel.id)
    |> limit(^limit)
    |> offset(^offset)
    |> preload(:provider)
    |> Repo.all()
  end

  @doc "Counts the live channels returned by `list_public_catalog/1`."
  @spec count_public_catalog(keyword()) :: non_neg_integer()
  def count_public_catalog(opts \\ []) do
    opts
    |> build_public_query()
    |> Repo.aggregate(:count, :id)
  end

  @doc """
  Marks a channel as dead because the upstream returned a terminal error
  (typically 404) during a resolve attempt. Called by the stream proxy.

  Null-safe: if the channel id is unknown or the row is gone, this is a no-op.
  """
  @spec mark_dead(integer() | nil) :: :ok
  def mark_dead(nil), do: :ok

  def mark_dead(channel_id) when is_integer(channel_id) do
    now = DateTime.utc_now(:second)

    {_count, _} =
      LiveChannel
      |> where(id: ^channel_id)
      |> Repo.update_all(set: [dead_since: now, updated_at: now])

    :ok
  end

  @doc """
  Whether `channel` answered 404 within the recheck window, the same window
  that hides it from listings. After the window it is tried again.
  """
  @spec dead?(map() | term()) :: boolean()
  def dead?(%{dead_since: %DateTime{} = since}) do
    cutoff = DateTime.add(DateTime.utc_now(), -@dead_recheck_hours * 3600, :second)
    DateTime.compare(since, cutoff) == :gt
  end

  def dead?(_channel), do: false

  @doc """
  Clears the dead flag for a channel (called implicitly by sync when the
  upstream lists the channel again, or after a successful resolve).
  """
  @spec mark_alive(integer()) :: :ok
  def mark_alive(channel_id) when is_integer(channel_id) do
    now = DateTime.utc_now(:second)

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
    offset = Keyword.get(opts, :offset, 0)
    show_adult = Keyword.get(opts, :show_adult, false)
    escaped = Helpers.escape_like(query)

    LiveChannel
    |> Access.visible_to_user(user_id)
    |> maybe_exclude_adult(show_adult)
    |> where([c, _p], ilike(c.name, ^"%#{escaped}%"))
    |> order_by([c], asc: c.name, desc: c.id)
    |> limit(^limit)
    |> offset(^offset)
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

    opts
    |> Keyword.delete(:search)
    |> build_public_query()
    |> RankedSearch.build([:name], query, limit: limit, rating_field: false)
    |> preload(:provider)
    |> Repo.all()
  end

  @doc "Returns category references for visible channel IDs used by personalization scoring."
  @spec recommendation_category_refs([integer()]) :: [{integer(), integer()}]
  def recommendation_category_refs([]), do: []

  def recommendation_category_refs(channel_ids) when is_list(channel_ids) do
    from(channel in LiveChannel,
      join: item_category in "item_categories",
      on: item_category.catalog_item_id == channel.catalog_item_id,
      where: channel.id in ^channel_ids,
      select: {channel.id, item_category.category_id}
    )
    |> Repo.all()
  end

  @doc "Lists adult-safe, active-provider channel candidates for AI personalization."
  @spec list_recommendation_candidates(integer(), keyword()) :: [LiveChannel.t()]
  def list_recommendation_candidates(user_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 24)
    exclude_ids = Keyword.get(opts, :exclude_ids, [])
    show_adult = Keyword.get(opts, :show_adult, false)

    LiveChannel
    |> Access.visible_to_user(user_id)
    |> where([_channel, provider], provider.provider_type == :xtream)
    |> where([channel], not is_nil(channel.stream_icon))
    |> exclude_dead()
    |> maybe_filter_recommendation_category(opts)
    |> maybe_exclude_recommendation_ids(exclude_ids)
    |> maybe_exclude_adult(show_adult)
    |> distinct(true)
    |> order_by([channel], asc: channel.name)
    |> limit(^limit)
    |> preload(:categories)
    |> Repo.all()
  end

  defp maybe_filter_recommendation_category(query, opts) do
    cond do
      category_ids = Keyword.get(opts, :category_ids) ->
        query
        |> join(:inner, [channel], item_category in "item_categories",
          on: item_category.catalog_item_id == channel.catalog_item_id
        )
        |> where(
          [_channel, _provider, item_category],
          item_category.category_id in ^category_ids
        )

      category_name = Keyword.get(opts, :category_name) ->
        escaped_name = Helpers.escape_like(String.downcase(category_name))

        query
        |> join(:inner, [channel], item_category in "item_categories",
          on: item_category.catalog_item_id == channel.catalog_item_id
        )
        |> join(:inner, [_channel, _provider, item_category], category in Category,
          on: category.id == item_category.category_id
        )
        |> where(
          [_channel, _provider, _item_category, category],
          ilike(category.name, ^"%#{escaped_name}%")
        )

      true ->
        query
    end
  end

  defp maybe_exclude_recommendation_ids(query, []), do: query

  defp maybe_exclude_recommendation_ids(query, ids) do
    where(query, [channel], channel.id not in ^ids)
  end

  defp maybe_exclude_adult(query, true), do: query
  defp maybe_exclude_adult(query, false), do: AdultFilter.exclude_adult_content(query)
end
