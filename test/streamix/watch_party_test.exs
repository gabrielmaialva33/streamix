defmodule Streamix.WatchPartyTest do
  use Streamix.DataCase, async: true

  alias Streamix.AccountsFixtures
  alias Streamix.IptvFixtures
  alias Streamix.WatchParty
  alias Streamix.WatchParty.{Message, Participant, Room}

  defp room_fixture do
    user = AccountsFixtures.user_fixture()
    provider = IptvFixtures.provider_fixture(user)
    movie = IptvFixtures.movie_fixture(provider, %{name: "Party Movie"})

    room =
      %Room{}
      |> Room.create_changeset(%{
        host_user_id: user.id,
        catalog_item_id: movie.catalog_item_id
      })
      |> Repo.insert!()

    %{room: room, user: user, movie: movie}
  end

  test "cross-context ownership stays in scalar foreign keys" do
    assert Message.__schema__(:type, :user_id) == :id
    assert Participant.__schema__(:type, :user_id) == :id
    assert Room.__schema__(:type, :host_user_id) == :id
    assert Room.__schema__(:type, :catalog_item_id) == :id

    refute :user in Message.__schema__(:associations)
    refute :user in Participant.__schema__(:associations)
    refute :host_user in Room.__schema__(:associations)
    refute :catalog_item in Room.__schema__(:associations)

    assert :user_email in Message.__schema__(:virtual_fields)
    assert :catalog_item in Room.__schema__(:virtual_fields)
  end

  test "room content is resolved through the IPTV facade" do
    %{room: room, movie: movie} = room_fixture()

    loaded_room = WatchParty.get_room_by_invite_with_content(room.invite_code)

    assert loaded_room.catalog_item.id == movie.catalog_item_id
    assert Streamix.Iptv.catalog_item_content_name(loaded_room.catalog_item) == movie.name
  end

  test "messages expose account email without a user association" do
    %{room: room, user: user} = room_fixture()

    assert {:ok, %Message{user_email: user_email}} =
             WatchParty.send_message(room.id, user.id, "e ai")

    assert user_email == user.email
    assert [%Message{content: "e ai", user_email: user_email}] = WatchParty.list_messages(room.id)
    assert user_email == user.email
  end
end
