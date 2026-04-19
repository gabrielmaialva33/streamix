defmodule StreamixWeb.Plugs.BearerAuthTest do
  use StreamixWeb.ConnCase, async: true

  import Streamix.AccountsFixtures

  alias Streamix.Accounts
  alias StreamixWeb.Plugs.BearerAuth

  describe "call/2 with a valid token" do
    test "assigns :current_user when the Bearer header is correct" do
      user = user_fixture()
      raw = Accounts.generate_user_session_token(user)
      encoded = Base.url_encode64(raw, padding: false)

      conn =
        build_conn(:get, "/api/v1/recommendations")
        |> put_req_header("authorization", "Bearer #{encoded}")
        |> BearerAuth.call([])

      refute conn.halted
      assert conn.assigns.current_user.id == user.id
    end

    test "accepts padded url-safe base64 too (TV client emits padded output)" do
      user = user_fixture()
      raw = Accounts.generate_user_session_token(user)
      encoded = Base.url_encode64(raw)

      conn =
        build_conn(:get, "/")
        |> put_req_header("authorization", "Bearer #{encoded}")
        |> BearerAuth.call([])

      refute conn.halted
      assert conn.assigns.current_user.id == user.id
    end

    test "tolerates lowercase scheme separator" do
      user = user_fixture()
      raw = Accounts.generate_user_session_token(user)
      encoded = Base.url_encode64(raw, padding: false)

      conn =
        build_conn(:get, "/")
        |> put_req_header("authorization", "bearer #{encoded}")
        |> BearerAuth.call([])

      refute conn.halted
      assert conn.assigns.current_user.id == user.id
    end
  end

  describe "call/2 rejecting bad input" do
    test "returns 401 when the Authorization header is absent" do
      conn =
        build_conn(:get, "/")
        |> BearerAuth.call([])

      assert conn.halted
      assert conn.status == 401
    end

    test "returns 401 when the token doesn't map to any user" do
      # 32 random bytes base64-encoded — well-formed but not a real
      # session token. Catches the `get_user_by_session_token` branch.
      bogus = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)

      conn =
        build_conn(:get, "/")
        |> put_req_header("authorization", "Bearer #{bogus}")
        |> BearerAuth.call([])

      assert conn.halted
      assert conn.status == 401
    end

    test "returns 401 when the base64 is malformed" do
      conn =
        build_conn(:get, "/")
        |> put_req_header("authorization", "Bearer !!!not-base64!!!")
        |> BearerAuth.call([])

      assert conn.halted
      assert conn.status == 401
    end
  end

  describe "call/2 with optional: true" do
    test "passes through when no Authorization header is present" do
      conn =
        build_conn(:get, "/")
        |> BearerAuth.call(optional: true)

      refute conn.halted
      assert conn.assigns[:current_user] == nil
    end

    test "still authenticates a valid Bearer header" do
      user = user_fixture()
      raw = Accounts.generate_user_session_token(user)
      encoded = Base.url_encode64(raw, padding: false)

      conn =
        build_conn(:get, "/")
        |> put_req_header("authorization", "Bearer #{encoded}")
        |> BearerAuth.call(optional: true)

      refute conn.halted
      assert conn.assigns.current_user.id == user.id
    end
  end
end
