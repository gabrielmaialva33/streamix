defmodule Streamix.Iptv.Games do
  @moduledoc "Synchronizes sports fixtures and lists only matches with visible channels."
  import Ecto.Query
  alias Streamix.Iptv.{Channels, LiveChannel, Provider, SportsMatch, XtreamClient}
  alias Streamix.Iptv.Games.Parser
  alias Streamix.Repo

  @updatable ~w(league title home_name home_logo_url away_name away_logo_url starts_at ends_at live_channel_id updated_at)a

  def enabled_providers do
    Repo.all(
      from p in Provider, where: p.games_enabled and p.is_active and p.provider_type == :xtream
    )
  end

  def sync(provider, opts \\ [])

  def sync(
        %Provider{games_enabled: true, is_active: true, provider_type: :xtream} = provider,
        opts
      ) do
    with {:ok, items} <- XtreamClient.get_games(provider, opts) do
      upsert(provider, items)
    end
  end

  def sync(_provider, _opts), do: {:error, :games_disabled}

  defp upsert(provider, items) do
    now = DateTime.utc_now(:second)

    parsed =
      Enum.flat_map(items, fn item ->
        case Parser.parse(item, provider) do
          {:ok, attrs, ids} -> [{attrs, ids}]
          :skip -> []
        end
      end)

    ids = Enum.flat_map(parsed, &elem(&1, 1)) |> Enum.uniq()

    channels =
      Repo.all(
        from c in LiveChannel,
          where: c.provider_id == ^provider.id and c.stream_id in ^ids,
          select: {c.stream_id, c.id}
      )
      |> Map.new()

    rows =
      Enum.map(parsed, fn {attrs, ids} ->
        Map.merge(attrs, %{
          provider_id: provider.id,
          live_channel_id: Enum.find_value(ids, &channels[&1]),
          inserted_at: now,
          updated_at: now
        })
      end)
      |> Enum.uniq_by(& &1.external_key)

    {count, _} =
      Repo.insert_all(SportsMatch, rows,
        on_conflict: {:replace, @updatable},
        conflict_target: [:provider_id, :external_key]
      )

    {:ok, count}
  end

  def prune(now \\ DateTime.utc_now()) do
    cutoff = DateTime.add(now, -12 * 3600)
    {count, _} = Repo.delete_all(from g in SportsMatch, where: g.ends_at < ^cutoff)
    count
  end

  def list(user_id, opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now(:second))

    visible =
      user_id
      |> Channels.visible_query(opts)
      |> where([_c, p], p.games_enabled)
      |> select([c], %{id: c.id, provider_id: c.provider_id})

    from(g in SportsMatch,
      join: c in subquery(visible),
      on: c.id == g.live_channel_id and c.provider_id == g.provider_id,
      # Today's schedule in São Paulo plus any match still on air (an
      # overnight one started yesterday); a finished match is no longer
      # playable as a game, since its channel has moved on.
      where:
        g.ends_at > ^now and
          (fragment(
             "(? AT TIME ZONE 'UTC' AT TIME ZONE 'America/Sao_Paulo')::date = (?::timestamp AT TIME ZONE 'UTC' AT TIME ZONE 'America/Sao_Paulo')::date",
             g.starts_at,
             type(^now, :utc_datetime)
           ) or g.starts_at <= ^now),
      order_by: [desc: g.starts_at <= ^now and g.ends_at > ^now, asc: g.starts_at, asc: g.id],
      select_merge: %{
        live: g.starts_at <= ^now and g.ends_at > ^now,
        local_starts_at:
          fragment("? AT TIME ZONE 'UTC' AT TIME ZONE 'America/Sao_Paulo'", g.starts_at)
      }
    )
    |> Repo.all()
  end
end
