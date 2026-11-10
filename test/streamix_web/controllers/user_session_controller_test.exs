defmodule StreamixWeb.UserSessionControllerTest do
  use StreamixWeb.ConnCase, async: false

  import Ecto.Query
  import Streamix.AccountsFixtures

  alias Streamix.Accounts.UserToken
  alias Streamix.Repo

  @remember_me_cookie "_streamix_user_remember_me"
  @persistent_session_max_age 60 * 24 * 60 * 60

  setup do
    previous_launcher =
      Application.get_env(:streamix, :ip_tracker_task_launcher, Streamix.TaskLauncher)

    previous_test_pid = Application.get_env(:streamix, :ip_tracker_task_launcher_test_pid)

    Application.put_env(
      :streamix,
      :ip_tracker_task_launcher,
      Streamix.TestSupport.IpTrackerTaskLauncherStub
    )

    Application.put_env(:streamix, :ip_tracker_task_launcher_test_pid, self())

    on_exit(fn ->
      Application.put_env(:streamix, :ip_tracker_task_launcher, previous_launcher)

      if previous_test_pid do
        Application.put_env(:streamix, :ip_tracker_task_launcher_test_pid, previous_test_pid)
      else
        Application.delete_env(:streamix, :ip_tracker_task_launcher_test_pid)
      end
    end)

    :ok
  end

  test "remembered login restores an expired browser session after 30 days", %{conn: conn} do
    user = user_fixture()

    conn =
      post(conn, ~p"/login", %{
        "user" => %{
          "email" => user.email,
          "password" => valid_user_password(),
          "remember_me" => "true"
        }
      })

    assert redirected_to(conn) == ~p"/home"

    assert %{
             value: signed_token,
             max_age: @persistent_session_max_age,
             http_only: true,
             same_site: "Lax"
           } = conn.resp_cookies[@remember_me_cookie]

    inserted_at = DateTime.add(DateTime.utc_now(:second), -30 * 24 * 60 * 60, :second)

    {1, nil} =
      Repo.update_all(
        from(token in UserToken,
          where: token.user_id == ^user.id and token.context == "session"
        ),
        set: [inserted_at: inserted_at]
      )

    restored_conn =
      build_conn()
      |> put_req_cookie(@remember_me_cookie, signed_token)
      |> get(~p"/settings")

    assert restored_conn.status == 200

    # The cookie restores the library secret along with the session token.
    assert restored_conn.assigns.current_scope.library_key == library_key_fixture(user)
  end

  test "login unlocks the library and keeps only its wrap in the database", %{conn: conn} do
    user = user_fixture()

    conn =
      post(conn, ~p"/login", %{
        "user" => %{"email" => user.email, "password" => valid_user_password()}
      })

    secret = get_session(conn, :library_secret)
    assert byte_size(secret) == 32

    token_row = Repo.get_by!(UserToken, user_id: user.id, context: "session")
    assert is_binary(token_row.library_key)
    assert :binary.match(token_row.library_key, secret) == :nomatch

    conn = conn |> recycle() |> get(~p"/history")
    assert html_response(conn, 200)
    assert conn.assigns.current_scope.library_key == library_key_fixture(user)
  end

  test "a session from before the library was sealed ends and must log in again", %{conn: conn} do
    user = user_fixture()
    legacy_token = Streamix.Accounts.generate_user_session_token(user)

    conn =
      conn
      |> init_test_session(%{})
      |> put_session(:user_token, legacy_token)
      |> get(~p"/history")

    assert redirected_to(conn) == ~p"/login"
    refute get_session(conn, :user_token)
    refute Repo.get_by(UserToken, token: legacy_token)
  end

  test "allows opting out of persistent login", %{conn: conn} do
    user = user_fixture()

    conn =
      post(conn, ~p"/login", %{
        "user" => %{
          "email" => user.email,
          "password" => valid_user_password(),
          "remember_me" => "false"
        }
      })

    refute Map.has_key?(conn.resp_cookies, @remember_me_cookie)
  end
end
