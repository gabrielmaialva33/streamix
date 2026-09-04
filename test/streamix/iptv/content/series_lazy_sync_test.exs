defmodule Streamix.Iptv.Content.SeriesLazySyncTest do
  use Streamix.DataCase, async: true

  import ExUnit.CaptureLog
  import Streamix.AccountsFixtures
  import Streamix.IptvFixtures

  alias Streamix.Catalog
  alias Streamix.Iptv.{Episode, Season}
  alias Streamix.Repo

  # A provider without Xtream credentials makes sync_series_details/1 log a
  # skip line instead of touching the network, which is a deterministic way to
  # observe whether the blocking sync was attempted at all.
  @skip_marker "Series details sync skipped"

  defp provider_without_credentials(user) do
    user
    |> provider_fixture(%{provider_type: "xtream", is_active: true})
    |> Ecto.Changeset.change(username: nil, password: nil)
    |> Repo.update!()
  end

  defp with_episode(series, provider) do
    season =
      %Season{}
      |> Season.changeset(%{season_number: 1, name: "T1", series_id: series.id})
      |> Repo.insert!()

    catalog_item = catalog_item_fixture("episode", provider.id)

    %Episode{}
    |> Episode.changeset(%{
      episode_id: System.unique_integer([:positive]),
      episode_num: 1,
      title: "S01E01",
      container_extension: "mp4",
      season_id: season.id
    })
    |> Ecto.Changeset.put_change(:catalog_item_id, catalog_item.id)
    |> Repo.insert!()

    series
  end

  test "a series that already has episodes does not block on the upstream" do
    user = user_fixture()
    provider = provider_without_credentials(user)

    series =
      provider
      |> series_content_fixture(%{name: "Com Episodios"})
      |> Ecto.Changeset.change(tmdb_id: nil)
      |> Repo.update!()
      |> with_episode(provider)

    log = capture_log(fn -> Catalog.get_series_with_sync!(series.id) end)

    # Xtream providers never send a tmdb_id, so keying the blocking sync on it
    # meant every single open paid for an upstream round trip forever.
    refute log =~ @skip_marker
  end

  test "a series with no episodes still syncs so the page is not empty" do
    user = user_fixture()
    provider = provider_without_credentials(user)

    series =
      provider
      |> series_content_fixture(%{name: "Sem Episodios"})
      |> Ecto.Changeset.change(tmdb_id: nil)
      |> Repo.update!()

    log = capture_log(fn -> Catalog.get_series_with_sync!(series.id) end)

    assert log =~ @skip_marker
  end

  test "a populated series with a tmdb_id also skips the upstream" do
    user = user_fixture()
    provider = provider_without_credentials(user)

    series =
      provider
      |> series_content_fixture(%{name: "Completa"})
      |> Ecto.Changeset.change(tmdb_id: "12345")
      |> Repo.update!()
      |> with_episode(provider)

    log = capture_log(fn -> Catalog.get_series_with_sync!(series.id) end)

    refute log =~ @skip_marker
  end
end
