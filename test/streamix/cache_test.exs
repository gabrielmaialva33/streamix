defmodule Streamix.CacheTest do
  use ExUnit.Case, async: false

  alias Streamix.Cache

  # Clear cache before each test
  setup do
    Cache.invalidate_all()
    :ok
  end

  describe "get/1 and set/2" do
    test "stores and retrieves a value" do
      assert :ok = Cache.set("test:key", "value")
      assert Cache.get("test:key") == "value"
    end

    test "returns nil for non-existent key" do
      assert is_nil(Cache.get("nonexistent:key"))
    end

    test "stores complex data structures" do
      data = %{
        "name" => "Test",
        "items" => [1, 2, 3],
        "nested" => %{"key" => "value"}
      }

      Cache.set("test:complex", data)
      assert Cache.get("test:complex") == data
    end

    test "stores lists" do
      list = ["a", "b", "c"]
      Cache.set("test:list", list)
      assert Cache.get("test:list") == list
    end

    test "respects TTL" do
      Cache.set("test:ttl", "value", 1)
      assert Cache.get("test:ttl") == "value"

      Process.sleep(1100)
      assert is_nil(Cache.get("test:ttl"))
    end
  end

  describe "delete/1" do
    test "removes a key" do
      Cache.set("test:delete", "value")
      assert Cache.get("test:delete") == "value"

      Cache.delete("test:delete")
      assert is_nil(Cache.get("test:delete"))
    end

    test "succeeds even if key doesn't exist" do
      assert :ok = Cache.delete("nonexistent:key")
    end
  end

  describe "delete_pattern/1" do
    test "deletes all keys matching pattern" do
      Cache.set("user:1:data", "data1")
      Cache.set("user:1:settings", "settings1")
      Cache.set("user:2:data", "data2")

      {:ok, count} = Cache.delete_pattern("user:1:*")

      assert count == 2
      assert is_nil(Cache.get("user:1:data"))
      assert is_nil(Cache.get("user:1:settings"))
      assert Cache.get("user:2:data") == "data2"
    end

    test "returns 0 if no keys match" do
      {:ok, count} = Cache.delete_pattern("nomatch:*")
      assert count == 0
    end
  end

  describe "fetch/3" do
    test "returns cached value if exists" do
      Cache.set("test:fetch", "cached")

      result = Cache.fetch("test:fetch", 3600, fn -> "computed" end)

      assert result == "cached"
    end

    test "computes and caches value if not exists" do
      result = Cache.fetch("test:compute", 3600, fn -> "computed" end)

      assert result == "computed"
      assert Cache.get("test:compute") == "computed"
    end

    test "recomputes after TTL expires" do
      Cache.fetch("test:expire", 1, fn -> "first" end)
      assert Cache.get("test:expire") == "first"

      Process.sleep(1100)

      result = Cache.fetch("test:expire", 3600, fn -> "second" end)
      assert result == "second"
    end
  end

  describe "cache keys" do
    test "categories_key/1 generates correct key" do
      assert Cache.categories_key(123) == "categories:user:123"
    end

    test "provider_categories_key/1 generates correct key" do
      assert Cache.provider_categories_key(456) == "categories:provider:456"
    end

    test "channel_count_key/1 generates correct key" do
      assert Cache.channel_count_key(789) == "channel_count:provider:789"
    end

    test "groups_key/1 generates correct key" do
      assert Cache.groups_key(111) == "groups:user:111"
    end
  end

  describe "invalidate_user/1" do
    test "invalidates all user-related cache entries" do
      Cache.set("categories:user:1", ["News"])
      Cache.set("groups:user:1", ["Group1"])
      Cache.set("other:user:1", "data")
      Cache.set("categories:user:2", ["Sports"])

      {:ok, count} = Cache.invalidate_user(1)

      assert count == 3
      assert is_nil(Cache.get("categories:user:1"))
      assert is_nil(Cache.get("groups:user:1"))
      assert is_nil(Cache.get("other:user:1"))
      assert Cache.get("categories:user:2") == ["Sports"]
    end
  end

  describe "invalidate_provider/1" do
    test "invalidates all provider-related cache entries" do
      Cache.set("categories:provider:1", ["News"])
      Cache.set("channel_count:provider:1", 100)
      Cache.set("categories:provider:2", ["Sports"])

      {:ok, count} = Cache.invalidate_provider(1)

      assert count == 2
      assert is_nil(Cache.get("categories:provider:1"))
      assert is_nil(Cache.get("channel_count:provider:1"))
      assert Cache.get("categories:provider:2") == ["Sports"]
    end
  end

  describe "invalidate_all/0" do
    test "clears all cache entries" do
      Cache.set("key1", "value1")
      Cache.set("key2", "value2")
      Cache.set("key3", "value3")

      Cache.invalidate_all()

      assert is_nil(Cache.get("key1"))
      assert is_nil(Cache.get("key2"))
      assert is_nil(Cache.get("key3"))
    end
  end
end
