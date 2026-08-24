defmodule Streamix.LibraryTest do
  use Streamix.DataCase, async: true
  use Oban.Testing, repo: Streamix.Repo

  alias Streamix.{Iptv, Library}
  alias Streamix.Workers.UpdateUserProfileWorker

  import Streamix.AccountsFixtures
  import Streamix.IptvFixtures

  test "manages favorites through the focused boundary while preserving Iptv compatibility" do
    user = user_fixture()
    provider = provider_fixture(user)
    channel = channel_fixture(provider)

    assert {:ok, favorite} =
             Library.add_favorite(user.id, "live_channel", channel.id)

    assert favorite.catalog_item_id == channel.catalog_item_id
    assert Library.favorite?(user.id, "live_channel", channel.id)
    assert Iptv.favorite?(user.id, "live_channel", channel.id)

    assert [%{content_id: content_id}] = Library.list_favorites(user.id)
    assert content_id == channel.id
    assert Iptv.list_favorites(user.id) == Library.list_favorites(user.id)
  end

  test "records history, schedules personalization, and remains available through Iptv" do
    user = user_fixture()
    provider = provider_fixture(user)
    channel = channel_fixture(provider)

    assert {:ok, entry} =
             Library.add_watch_history(user.id, "live_channel", channel.id, %{
               duration_seconds: 300
             })

    assert entry.user_id == user.id
    assert entry.catalog_item_id == channel.catalog_item_id

    assert [%{id: entry_id, duration_seconds: 300}] = Library.list_watch_history(user.id)
    assert entry_id == entry.id
    assert Iptv.list_watch_history(user.id) == Library.list_watch_history(user.id)

    assert_enqueued(
      worker: UpdateUserProfileWorker,
      args: %{user_id: user.id}
    )
  end
end
