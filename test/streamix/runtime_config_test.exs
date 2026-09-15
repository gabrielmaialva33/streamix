defmodule Streamix.RuntimeConfigTest do
  use ExUnit.Case, async: false

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

  describe "provider encryption key validation in runtime.exs" do
    @required_prod_env %{
      "DATABASE_URL" => "ecto://postgres:postgres@localhost/streamix_prod",
      "SECRET_KEY_BASE" => String.duplicate("a", 64),
      "LIVE_VIEW_SIGNING_SALT" => String.duplicate("b", 32),
      "API_KEYS" => "test-api-key"
    }

    test "raises in production when PROVIDER_ENCRYPTION_KEY is missing, empty, or whitespace" do
      original_env = System.get_env()

      try do
        System.put_env(@required_prod_env)

        System.delete_env("PROVIDER_ENCRYPTION_KEY")

        assert_raise RuntimeError, ~r/PROVIDER_ENCRYPTION_KEY is missing or empty/, fn ->
          Config.Reader.read!("config/runtime.exs", env: :prod)
        end

        System.put_env("PROVIDER_ENCRYPTION_KEY", "")

        assert_raise RuntimeError, ~r/PROVIDER_ENCRYPTION_KEY is missing or empty/, fn ->
          Config.Reader.read!("config/runtime.exs", env: :prod)
        end

        System.put_env("PROVIDER_ENCRYPTION_KEY", "   ")

        assert_raise RuntimeError, ~r/PROVIDER_ENCRYPTION_KEY is missing or empty/, fn ->
          Config.Reader.read!("config/runtime.exs", env: :prod)
        end
      after
        restore_env(original_env)
      end
    end

    test "allows missing PROVIDER_ENCRYPTION_KEY in dev and test environments" do
      original_env = System.get_env()

      try do
        System.delete_env("PROVIDER_ENCRYPTION_KEY")

        config_test = Config.Reader.read!("config/runtime.exs", env: :test)
        assert Keyword.get(config_test[:streamix] || [], :provider_encryption_key) == nil

        System.put_env("DATABASE_URL", "ecto://postgres:postgres@localhost/streamix_dev")

        # Reading dev config does not raise even if PROVIDER_ENCRYPTION_KEY is unset in environment
        assert is_list(Config.Reader.read!("config/runtime.exs", env: :dev))
      after
        restore_env(original_env)
      end
    end

    test "succeeds in production when PROVIDER_ENCRYPTION_KEY is present" do
      original_env = System.get_env()

      try do
        System.put_env(@required_prod_env)
        System.put_env("PROVIDER_ENCRYPTION_KEY", "dummy_key_at_least_32_bytes_long_1234567")

        config = Config.Reader.read!("config/runtime.exs", env: :prod)

        assert config[:streamix][:provider_encryption_key] ==
                 "dummy_key_at_least_32_bytes_long_1234567"
      after
        restore_env(original_env)
      end
    end

    defp restore_env(original_env) do
      current_keys = System.get_env() |> Map.keys()
      original_keys = Map.keys(original_env)

      for key <- current_keys -- original_keys do
        System.delete_env(key)
      end

      System.put_env(original_env)
    end
  end
end
