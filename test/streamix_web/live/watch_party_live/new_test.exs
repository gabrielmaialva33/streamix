defmodule StreamixWeb.WatchPartyLive.NewTest do
  use StreamixWeb.ConnCase

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Streamix.IptvFixtures

  alias Streamix.{Billing, Repo}
  alias Streamix.WatchParty.{Room, RoomServer}

  setup :register_and_log_in_user

  setup %{user: user} do
    provider = provider_fixture(user)
    movie = movie_fixture(provider, %{name: "Create Party Movie"})
    %{provider: provider, movie: movie}
  end

  test "opening the creation route only renders confirmation and creates no room", %{
    conn: conn,
    movie: movie,
    user: user
  } do
    {:ok, view, html} = live(conn, ~p"/party/new/movie/#{movie.id}")

    assert html =~ "Criar uma Watch Party?"
    assert has_element?(view, "button[phx-click='create']")
    refute active_room?(user.id, movie.catalog_item_id)
  end

  test "creation without the feature redirects to the upgrade screen", %{
    conn: conn,
    movie: movie,
    user: user
  } do
    {:ok, view, _html} = live(conn, ~p"/party/new/movie/#{movie.id}")

    render_click(view, "create", %{})

    assert_redirect(view, "/plans?upgrade=watch_party")
    refute active_room?(user.id, movie.catalog_item_id)
  end

  test "GIndex creation resolves the canonical movie and preserves its playback source", %{
    conn: conn,
    user: user
  } do
    grant_watch_party!(user)

    provider =
      provider_fixture(user, %{
        provider_type: "gindex",
        name: "GIndex Party Test"
      })

    movie =
      movie_fixture(provider, %{
        name: "GIndex Party Movie",
        gindex_path: "/Movies/GIndex Party Movie.mkv"
      })

    {:ok, view, _html} = live(conn, ~p"/party/new/gindex/#{movie.id}")
    render_click(view, "create", %{})

    room =
      Repo.one!(
        from(room in Room,
          where:
            room.host_user_id == ^user.id and room.catalog_item_id == ^movie.catalog_item_id and
              room.status == "active"
        )
      )

    assert room.source_type == "gindex"
    assert room.source_id == movie.id
    assert_redirect(view, "/party/#{room.invite_code}/watch")

    RoomServer.stop(room.id)
  end

  defp active_room?(user_id, catalog_item_id) do
    Repo.exists?(
      from(room in Room,
        where:
          room.host_user_id == ^user_id and room.catalog_item_id == ^catalog_item_id and
            room.status == "active"
      )
    )
  end

  defp grant_watch_party!(user) do
    unique = System.unique_integer([:positive])

    plan =
      Billing.ensure_plan!(%{
        name: "Watch Party Create Test #{unique}",
        slug: "watch-party-create-test-#{unique}",
        description: "Creation flow test plan",
        price_cents: 0,
        currency: "USD",
        billing_interval: "month",
        active: true,
        grants_global_access: false,
        features: %{watch_party: true}
      })

    Billing.ensure_manual_subscription!(user, plan, %{
      status: "active",
      starts_at: DateTime.utc_now(:second),
      external_reference: "watch-party-create-test:#{unique}"
    })
  end
end
