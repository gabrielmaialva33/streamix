defmodule Streamix.RuntimeConfigTest do
  use ExUnit.Case, async: true

  alias Streamix.RuntimeConfig

  test "loads dotenv only in development and keeps test configuration process-only" do
    system_env = %{"DATABASE_URL" => "process-value"}
    test_pid = self()

    loaded =
      RuntimeConfig.load_environment(:dev, system_env, fn sources ->
        send(test_pid, {:dotenv_sources, sources})
        %{"DATABASE_URL" => "loaded-value"}
      end)

    assert loaded == %{"DATABASE_URL" => "loaded-value"}
    assert_receive {:dotenv_sources, [".env", ^system_env]}

    rejecting_loader = fn _sources -> flunk("dotenv must not load outside development") end

    assert RuntimeConfig.load_environment(:test, system_env, rejecting_loader) == system_env
    assert RuntimeConfig.load_environment(:prod, system_env, rejecting_loader) == system_env
  end

  test "publishes isolated local defaults for test services" do
    database = RuntimeConfig.local_test_database_url() |> URI.parse()
    redis = RuntimeConfig.local_test_redis_url() |> URI.parse()

    assert database.scheme == "ecto"
    assert database.host == "localhost"
    assert database.path == "/streamix_test"
    assert redis.host == "localhost"
    assert redis.path in [nil, ""]
  end

  test "parses explicit booleans and preserves the default when unset" do
    assert RuntimeConfig.boolean!("FEATURE_FLAG", " YES ", false)
    refute RuntimeConfig.boolean!("FEATURE_FLAG", "off", true)
    assert RuntimeConfig.boolean!("FEATURE_FLAG", nil, true)
  end

  test "rejects ambiguous boolean values with the environment variable name" do
    assert_raise ArgumentError, ~r/FEATURE_FLAG.*boolean/i, fn ->
      RuntimeConfig.boolean!("FEATURE_FLAG", "sometimes", false)
    end
  end

  test "parses bounded integers and rejects malformed or out-of-range values" do
    assert RuntimeConfig.integer!("PORT", "4000", 3000, min: 1, max: 65_535) == 4_000
    assert RuntimeConfig.integer!("POOL_SIZE", nil, 10, min: 1) == 10

    assert_raise ArgumentError, ~r/PORT.*integer/i, fn ->
      RuntimeConfig.integer!("PORT", "4000oops", 3000, min: 1)
    end

    assert_raise ArgumentError, ~r/PORT.*at most 65535/i, fn ->
      RuntimeConfig.integer!("PORT", "70000", 3000, max: 65_535)
    end
  end

  test "normalizes comma-separated values and removes blanks and duplicates" do
    assert RuntimeConfig.csv(" first, ,second,first ") == ["first", "second"]
    assert RuntimeConfig.csv(nil) == []
  end
end
