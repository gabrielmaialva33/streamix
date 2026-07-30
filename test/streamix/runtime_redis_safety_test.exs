defmodule Streamix.RuntimeRedisSafetyTest do
  use ExUnit.Case, async: true

  alias Streamix.RuntimeRedisSafety

  test "derives database 15 from a local shared Redis URL" do
    assert RuntimeRedisSafety.prepare_test_url!("redis://localhost:6379") ==
             "redis://localhost:6379/15"
  end

  test "preserves an explicit local test Redis database" do
    assert RuntimeRedisSafety.prepare_test_url!("redis://localhost:6379/14", explicit?: true) ==
             "redis://localhost:6379/14"
  end

  test "rejects a remote Redis host by default without exposing credentials" do
    error =
      assert_raise RuntimeError, fn ->
        RuntimeRedisSafety.prepare_test_url!(
          "redis://test-user:super-secret@cache.example.com:6379/15",
          explicit?: true
        )
      end

    assert error.message =~ "cache.example.com"
    refute error.message =~ "test-user"
    refute error.message =~ "super-secret"
  end

  test "requires a non-zero database for an intentional remote test Redis" do
    assert_raise RuntimeError, ~r/non-zero Redis database/, fn ->
      RuntimeRedisSafety.prepare_test_url!("redis://cache.example.com:6379/0",
        explicit?: true,
        allow_remote?: true
      )
    end
  end

  test "requires an explicit TEST_REDIS_URL for intentional remote Redis" do
    assert_raise RuntimeError, ~r/TEST_REDIS_URL/, fn ->
      RuntimeRedisSafety.prepare_test_url!("redis://cache.example.com:6379/15",
        allow_remote?: true
      )
    end
  end

  test "allows an intentional isolated remote Redis database" do
    assert RuntimeRedisSafety.prepare_test_url!("redis://cache.example.com:6379/15",
             explicit?: true,
             allow_remote?: true
           ) == "redis://cache.example.com:6379/15"
  end

  test "derives database 15 for an allowlisted Compose hostname" do
    assert RuntimeRedisSafety.prepare_test_url!("redis://streamix-redis:6379",
             allowed_hosts: ["streamix-redis"]
           ) == "redis://streamix-redis:6379/15"
  end
end
