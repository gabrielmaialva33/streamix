defmodule Streamix.RuntimeDatabaseSafetyTest do
  use ExUnit.Case, async: true

  alias Streamix.RuntimeDatabaseSafety

  test "allows loopback and Compose test databases" do
    assert RuntimeDatabaseSafety.validate_test_url!(
             "ecto://streamix:secret@127.0.0.1/streamix_test"
           )

    assert RuntimeDatabaseSafety.validate_test_url!(
             "ecto://streamix:secret@postgres/streamix_test2"
           )
  end

  test "allows an explicitly configured Compose hostname" do
    assert RuntimeDatabaseSafety.validate_test_url!(
             "ecto://streamix:secret@database/streamix_test",
             allowed_hosts: ["database"]
           )
  end

  test "does not let the Compose allowlist bypass remote-host protection" do
    assert_raise RuntimeError, ~r/must be local Compose service names/, fn ->
      RuntimeDatabaseSafety.validate_test_url!(
        "ecto://streamix:secret@10.8.0.1/streamix_test",
        allowed_hosts: ["10.8.0.1"]
      )
    end
  end

  test "blocks remote hosts without exposing credentials" do
    error =
      assert_raise RuntimeError, ~r/remote database host "10\.8\.0\.1".*"streamix_test"/s, fn ->
        RuntimeDatabaseSafety.validate_test_url!(
          "ecto://streamix:top-secret@10.8.0.1/streamix_test"
        )
      end

    refute Exception.message(error) =~ "top-secret"
  end

  test "requires an explicit remote opt-in" do
    assert RuntimeDatabaseSafety.validate_test_url!(
             "ecto://streamix:secret@10.8.0.1/streamix_test",
             allow_remote?: true
           )
  end

  test "never accepts a production-shaped database name" do
    assert_raise RuntimeError, ~r/must end in _test/, fn ->
      RuntimeDatabaseSafety.validate_test_url!(
        "ecto://streamix:secret@127.0.0.1/streamix_prod",
        allow_remote?: true
      )
    end
  end
end
