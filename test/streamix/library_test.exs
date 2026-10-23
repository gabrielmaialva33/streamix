defmodule Streamix.LibraryTest do
  use Streamix.DataCase, async: true

  alias Streamix.{Accounts, Iptv, Library}
  alias Streamix.Iptv.{Favorite, WatchProgress}

  import Streamix.AccountsFixtures
  import Streamix.IptvFixtures

  test "manages favorites through the focused boundary while preserving Iptv compatibility" do
    user = user_fixture()
    key = library_key_fixture(user)
    provider = provider_fixture(user)
    channel = channel_fixture(provider)

    assert {:ok, favorite} = Library.add_favorite(key, "live_channel", channel.id)

    assert favorite.catalog_item_id == channel.catalog_item_id
    assert Library.favorite?(key, "live_channel", channel.id)
    assert Iptv.favorite?(key, "live_channel", channel.id)

    assert [%{content_id: content_id}] = Library.list_favorites(key)
    assert content_id == channel.id
    assert Iptv.list_favorites(key) == Library.list_favorites(key)
  end

  test "records history and remains available through Iptv" do
    user = user_fixture()
    key = library_key_fixture(user)
    provider = provider_fixture(user)
    channel = channel_fixture(provider)

    assert {:ok, entry} =
             Library.add_watch_history(key, "live_channel", channel.id, %{duration_seconds: 300})

    assert entry.user_id == user.id
    assert entry.catalog_item_id == channel.catalog_item_id

    assert [%{id: entry_id, duration_seconds: 300}] = Library.list_watch_history(key)
    assert entry_id == entry.id
    assert Iptv.list_watch_history(key) == Library.list_watch_history(key)
  end

  describe "what the database holds" do
    test "rows name neither the content nor its catalog item" do
      user = user_fixture()
      key = library_key_fixture(user)
      provider = provider_fixture(user)
      movie = movie_fixture(provider, %{name: "Something Private"})

      {:ok, _} = Library.add_watch_history(key, "movie", movie.id, %{progress_seconds: 42})
      {:ok, _} = Library.add_favorite(key, "movie", movie.id)

      # No content reference and no plaintext timestamps either.
      assert columns("watch_progress") == ~w(id user_id item_digest sealed)
      assert columns("favorites") == ~w(id user_id item_digest sealed)

      [progress] = Repo.all(WatchProgress)
      [favorite] = Repo.all(Favorite)

      # Ids are a couple of digits in a fresh database and would match random
      # ciphertext bytes, so look for what plaintext JSON would contain.
      for blob <- [progress.sealed, progress.item_digest, favorite.sealed, favorite.item_digest],
          plaintext <- [
            ~s("catalog_item_id":#{movie.catalog_item_id}),
            "catalog_item_id",
            "content_type",
            "movie",
            "Something Private"
          ] do
        assert :binary.match(blob, plaintext) == :nomatch
      end
    end

    test "rows moved to another user open for nobody" do
      owner = user_fixture()
      other = user_fixture()
      owner_key = library_key_fixture(owner)
      other_key = library_key_fixture(other)
      provider = provider_fixture(owner, %{visibility: :global, is_system: true})
      movie = movie_fixture(provider)

      {:ok, _} = Library.add_watch_history(owner_key, "movie", movie.id, %{progress_seconds: 42})
      {:ok, _} = Library.add_favorite(owner_key, "movie", movie.id)

      # What an operator with database access could try: hand the rows to a
      # user whose key they hold.
      Repo.update_all(WatchProgress, set: [user_id: other.id])
      Repo.update_all(Favorite, set: [user_id: other.id])

      assert Library.list_watch_history(other_key) == []
      assert Library.list_favorites(other_key) == []
      refute Library.favorite?(other_key, "movie", movie.id)
    end

    test "a favorite and a history entry for the same content have unrelated digests" do
      user = user_fixture()
      key = library_key_fixture(user)
      provider = provider_fixture(user)
      movie = movie_fixture(provider)

      {:ok, _} = Library.add_watch_history(key, "movie", movie.id, %{progress_seconds: 1})
      {:ok, _} = Library.add_favorite(key, "movie", movie.id)

      refute Repo.one!(WatchProgress).item_digest == Repo.one!(Favorite).item_digest
    end

    test "the same content gets a different digest for each user" do
      provider = provider_fixture(user_fixture(), %{visibility: :global, is_system: true})
      movie = movie_fixture(provider)

      for user <- [user_fixture(), user_fixture()] do
        {:ok, _} = Library.add_favorite(library_key_fixture(user), "movie", movie.id)
      end

      assert [left, right] = Repo.all(Favorite)
      refute left.item_digest == right.item_digest
    end
  end

  describe "keys" do
    test "the same password unlocks the same key, and a session wrap needs its secret" do
      user = user_fixture()
      key = library_key_fixture(user)

      assert {:ok, ^key} = Library.unlock(user, valid_user_password())

      {secret, sealed} = Library.seal_session(key)
      assert {:ok, ^key} = Library.open_session(user.id, secret, sealed)

      assert :error =
               Library.open_session(user.id, :crypto.strong_rand_bytes(32), sealed)

      assert :error = Library.open_session(user.id + 1, secret, sealed)
      assert :error = Library.open_session(user.id, nil, sealed)
      assert :error = Library.open_session(user.id, secret, nil)
    end

    test "a key never shows its secret when inspected" do
      key = library_key_fixture(user_fixture())

      assert inspect(key) == "#Streamix.Library.Key<user_id: #{key.user_id}, ...>"
    end

    test "a password that does not open the stored key never discards it" do
      user = user_fixture()
      provider = provider_fixture(user)
      channel = channel_fixture(provider)
      {:ok, _} = Library.add_favorite(library_key_fixture(user), "live_channel", channel.id)

      assert {:error, :locked} = Library.unlock(user, "not the password the key was wrapped with")

      assert [_favorite] = Repo.all(Favorite)
      assert [%{content_id: content_id}] = Library.list_favorites(library_key_fixture(user))
      assert content_id == channel.id
    end

    test "every password bcrypt accepts at login opens the key" do
      # bcrypt reads 72 bytes at most: a longer password whose first 72 bytes
      # match logs in, so it must open the same key.
      password = String.duplicate("p", 72)
      user = user_fixture(%{password: password})
      {:ok, key} = Library.unlock(user, password)

      longer = password <> "and then some"
      assert %{id: id} = Accounts.get_user_by_email_and_password(user.email, longer)
      assert id == user.id
      assert {:ok, ^key} = Library.unlock(user, longer)
    end

    test "changing the password with the current one keeps the library" do
      user = user_fixture()
      provider = provider_fixture(user)
      channel = channel_fixture(provider)
      {:ok, _} = Library.add_favorite(library_key_fixture(user), "live_channel", channel.id)

      new_password = "a brand new password"

      assert {:ok, {user, _expired}} =
               Accounts.update_user_password(user, valid_user_password(), %{
                 password: new_password
               })

      assert {:ok, key} = Library.unlock(user, new_password)
      assert [%{content_id: content_id}] = Library.list_favorites(key)
      assert content_id == channel.id
    end

    test "replacing the password without the current one forgets the library" do
      user = user_fixture()
      provider = provider_fixture(user)
      channel = channel_fixture(provider)
      {:ok, _} = Library.add_favorite(library_key_fixture(user), "live_channel", channel.id)

      assert {:ok, {user, _expired}} =
               Accounts.update_user_password(user, %{password: "nobody knew the old one"})

      assert Repo.all(Favorite) == []
      assert {:ok, key} = Library.unlock(user, "nobody knew the old one")
      assert Library.list_favorites(key) == []
    end
  end

  describe "plaintext rows from before the library was sealed" do
    test "are sealed and deleted at the next unlock" do
      user = user_fixture()
      provider = provider_fixture(user)
      movie = movie_fixture(provider)
      channel = channel_fixture(provider)
      watched_at = ~U[2026-10-01 20:00:00Z]

      Repo.insert_all("legacy_watch_progress", [
        %{
          user_id: user.id,
          catalog_item_id: movie.catalog_item_id,
          progress_seconds: 600,
          duration_seconds: 7200,
          completed: false,
          last_watched_at: watched_at,
          inserted_at: watched_at,
          updated_at: watched_at
        }
      ])

      Repo.insert_all("legacy_favorites", [
        %{user_id: user.id, catalog_item_id: channel.catalog_item_id}
      ])

      {:ok, key} = Library.unlock(user, valid_user_password())

      assert [%{content_id: movie_id, progress_seconds: 600, watched_at: ^watched_at}] =
               Library.list_watch_history(key)

      assert movie_id == movie.id
      assert [%{content_id: channel_id}] = Library.list_favorites(key)
      assert channel_id == channel.id

      assert Repo.aggregate("legacy_watch_progress", :count) == 0
      assert Repo.aggregate("legacy_favorites", :count) == 0
    end

    test "of users who never come back can be purged" do
      user = user_fixture()
      channel = channel_fixture(provider_fixture(user))

      Repo.insert_all("legacy_favorites", [
        %{user_id: user.id, catalog_item_id: channel.catalog_item_id}
      ])

      assert %{favorites: 1, watch_progress: 0} = Library.purge_legacy_plaintext()
      assert Repo.aggregate("legacy_favorites", :count) == 0
    end
  end

  defp columns(table) do
    Repo.query!(
      """
      SELECT column_name FROM information_schema.columns
      WHERE table_schema = 'public' AND table_name = $1
      ORDER BY ordinal_position
      """,
      [table]
    ).rows
    |> List.flatten()
  end
end
