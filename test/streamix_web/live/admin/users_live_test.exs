defmodule StreamixWeb.Admin.UsersLiveTest do
  use StreamixWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Streamix.AccountsFixtures

  alias Streamix.{Accounts, Billing}

  setup %{conn: conn} do
    admin = admin_user_fixture()
    conn = log_in_user(conn, admin)
    %{conn: conn, admin: admin}
  end

  describe "users listing" do
    test "shows users table", %{conn: conn, admin: admin} do
      {:ok, _lv, html} = live(conn, ~p"/admin/users")
      assert html =~ admin.email
    end

    test "filters by email search", %{conn: conn} do
      _target = user_fixture(%{email: "findme@example.com"})
      _other = user_fixture(%{email: "notme@example.com"})

      {:ok, lv, _html} = live(conn, ~p"/admin/users")

      html = lv |> form("#search-form", %{search: "findme"}) |> render_submit()

      assert html =~ "findme@example.com"
      refute html =~ "notme@example.com"
    end
  end

  describe "user edit" do
    test "shows user details", %{conn: conn} do
      user = user_fixture(%{email: "target@example.com"})
      {:ok, _lv, html} = live(conn, ~p"/admin/users/#{user.id}")
      assert html =~ "target@example.com"
    end

    test "updates user role", %{conn: conn} do
      user = user_fixture()
      {:ok, lv, _html} = live(conn, ~p"/admin/users/#{user.id}")

      lv
      |> form("#user-role-form", user: %{role: "moderator"})
      |> render_submit()

      assert Accounts.role_name(Accounts.get_user!(user.id)) == "moderator"
    end

    test "creates manual subscription", %{conn: conn} do
      user = user_fixture()

      {:ok, plan} =
        Billing.create_plan(%{
          name: "Test",
          slug: "test-sub-#{System.unique_integer([:positive])}",
          price_cents: 999,
          currency: "BRL",
          billing_interval: "month",
          grants_global_access: true
        })

      {:ok, lv, _html} = live(conn, ~p"/admin/users/#{user.id}")

      lv
      |> form("#subscription-form", subscription: %{plan_id: plan.id})
      |> render_submit()

      assert Billing.subscribed?(Streamix.Repo.reload!(user))
    end

    test "cancels subscription", %{conn: conn} do
      user = user_fixture()

      {:ok, plan} =
        Billing.create_plan(%{
          name: "Cancel Test",
          slug: "cancel-test-#{System.unique_integer([:positive])}",
          price_cents: 999,
          currency: "BRL",
          billing_interval: "month",
          grants_global_access: true
        })

      {:ok, _sub} =
        Billing.create_manual_subscription(user, plan, %{
          status: "active",
          starts_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })

      {:ok, lv, _html} = live(conn, ~p"/admin/users/#{user.id}")

      lv |> element("#cancel-subscription-btn") |> render_click()

      refute Billing.subscribed?(Streamix.Repo.reload!(user))
    end
  end
end
