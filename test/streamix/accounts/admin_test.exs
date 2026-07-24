defmodule Streamix.Accounts.AdminTest do
  use Streamix.DataCase, async: true

  alias Streamix.Accounts

  import Streamix.AccountsFixtures

  describe "list_users/1" do
    test "returns all users" do
      user = user_fixture()
      users = Accounts.list_users([])
      assert Enum.any?(users, &(&1.id == user.id))
    end

    test "filters by email search" do
      user = user_fixture(%{email: "searchable@test.com"})
      _other = user_fixture()

      users = Accounts.list_users(search: "searchable")
      assert length(users) == 1
      assert hd(users).id == user.id
    end

    test "paginates results" do
      for _ <- 1..5, do: user_fixture()

      page1 = Accounts.list_users(page: 1, per_page: 2)
      page2 = Accounts.list_users(page: 2, per_page: 2)

      assert length(page1) == 2
      assert length(page2) == 2
      assert hd(page1).id != hd(page2).id
    end
  end

  describe "count_users/0" do
    test "returns total user count" do
      user_fixture()
      assert Accounts.count_users() >= 1
    end
  end

  describe "update_user_role/2" do
    test "updates role to admin" do
      user = user_fixture()
      assert {:ok, updated} = Accounts.update_user_role(user, "admin")
      assert Accounts.admin?(updated)
    end

    test "updates role to moderator" do
      user = user_fixture()
      assert {:ok, updated} = Accounts.update_user_role(user, "moderator")
      assert Accounts.role_name(updated) == "moderator"
    end

    test "rejects invalid role" do
      user = user_fixture()

      assert_raise Ecto.NoResultsError, fn ->
        Accounts.update_user_role(user, "superadmin")
      end
    end
  end

  describe "update_user_settings_admin/2" do
    test "toggles show_adult_content" do
      user = user_fixture()

      assert {:ok, updated} =
               Accounts.update_user_settings_admin(user, %{show_adult_content: true})

      assert updated.show_adult_content == true
    end

    test "validates subtitle preferences" do
      user = user_fixture()

      assert {:ok, updated} =
               Accounts.update_user_settings_admin(user, %{
                 subtitles_enabled: false,
                 subtitle_language: "es",
                 subtitle_offset_ms: -500
               })

      refute updated.subtitles_enabled
      assert updated.subtitle_language == "es"
      assert updated.subtitle_offset_ms == -500

      assert {:error, changeset} =
               Accounts.update_user_settings_admin(user, %{subtitle_offset_ms: 700_000})

      assert "must be less than or equal to 600000" in errors_on(changeset).subtitle_offset_ms
    end
  end
end
