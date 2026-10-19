defmodule Streamix.Iptv.GamesAccessTest do
  use Streamix.DataCase, async: true
  import Streamix.IptvFixtures
  import Streamix.AccountsFixtures
  import Streamix.GamesFixtures
  alias Streamix.{Catalog, Providers}

  test "uses channel visibility, health, provider opt-in and adult rules" do
    owner = user_fixture()
    other = user_fixture()
    public = global_provider_fixture(%{games_enabled: true})

    private =
      provider_fixture(owner) |> Ecto.Changeset.change(games_enabled: true) |> Repo.update!()

    public_channel = channel_fixture(public)
    private_channel = channel_fixture(private)
    public_game = game_fixture(public, public_channel)
    private_game = game_fixture(private, private_channel)
    _missing = game_fixture(public, nil)
    assert Enum.map(Catalog.list_games(nil), & &1.id) == [public_game.id]
    assert Enum.map(Catalog.list_games(other.id), & &1.id) == [public_game.id]

    assert MapSet.new(Enum.map(Catalog.list_games(owner.id), & &1.id)) ==
             MapSet.new([public_game.id, private_game.id])

    public_channel
    |> Ecto.Changeset.change(dead_since: DateTime.utc_now(:second))
    |> Repo.update!()

    assert Catalog.list_games(nil) == []
    public_channel |> Ecto.Changeset.change(dead_since: nil) |> Repo.update!()
    public |> Ecto.Changeset.change(health_status: :degraded) |> Repo.update!()
    assert Catalog.list_games(nil) == []

    public
    |> Ecto.Changeset.change(health_status: :healthy, games_enabled: false)
    |> Repo.update!()

    assert Catalog.list_games(nil) == []
    public |> Ecto.Changeset.change(games_enabled: true, is_active: false) |> Repo.update!()
    assert Catalog.list_games(nil) == []
  end

  test "adult channels are hidden unless user opts in" do
    provider = global_provider_fixture(%{games_enabled: true})
    channel = channel_fixture(provider)
    game_fixture(provider, channel)

    category =
      Repo.insert!(%Streamix.Iptv.Category{
        provider_id: provider.id,
        external_id: "adult",
        name: "Adult",
        type: "live",
        is_adult: true
      })

    Repo.insert_all("item_categories", [
      %{catalog_item_id: channel.catalog_item_id, category_id: category.id}
    ])

    assert Catalog.list_games(nil) == []
    assert [_game] = Catalog.list_games(nil, show_adult: true)
  end

  test "today uses Sao Paulo midnight, includes ongoing overnight games and orders live first" do
    provider = global_provider_fixture(%{games_enabled: true})
    channel = channel_fixture(provider)
    now = ~U[2026-10-20 02:30:00Z]

    ended =
      game_fixture(provider, channel, %{
        starts_at: ~U[2026-10-19 12:00:00Z],
        ends_at: ~U[2026-10-19 14:00:00Z]
      })

    live =
      game_fixture(provider, channel, %{
        starts_at: ~U[2026-10-20 02:00:00Z],
        ends_at: ~U[2026-10-20 04:00:00Z]
      })

    tomorrow =
      game_fixture(provider, channel, %{
        starts_at: ~U[2026-10-20 03:00:00Z],
        ends_at: ~U[2026-10-20 05:00:00Z]
      })

    assert [first, second] = Catalog.list_games(nil, now: now)
    assert first.id == live.id and first.live
    assert NaiveDateTime.compare(first.local_starts_at, ~N[2026-10-19 23:00:00]) == :eq
    assert second.id == ended.id and not second.live

    assert Enum.map(Catalog.list_games(nil, now: ~U[2026-10-20 03:30:00Z]), & &1.id) == [
             live.id,
             tomorrow.id
           ]
  end

  test "prunes only matches finished more than twelve hours ago" do
    provider = global_provider_fixture(%{games_enabled: true})
    now = ~U[2026-10-19 18:00:00Z]

    old =
      game_fixture(provider, nil, %{
        starts_at: DateTime.add(now, -60_000),
        ends_at: DateTime.add(now, -43_201)
      })

    keep =
      game_fixture(provider, nil, %{
        starts_at: DateTime.add(now, -60_000),
        ends_at: DateTime.add(now, -43_200)
      })

    assert Providers.prune_games(now) == 1
    refute Repo.get(Streamix.Iptv.SportsMatch, old.id)
    assert Repo.get(Streamix.Iptv.SportsMatch, keep.id)
  end
end
