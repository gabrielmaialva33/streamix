defmodule Streamix.Iptv.TmdbClientTest do
  use ExUnit.Case, async: false

  alias Streamix.Iptv.TmdbClient

  setup do
    default = Application.get_env(:streamix, :tmdb)
    gindex = Application.get_env(:streamix, :tmdb_gindex)

    on_exit(fn ->
      if default,
        do: Application.put_env(:streamix, :tmdb, default),
        else: Application.delete_env(:streamix, :tmdb)

      if gindex,
        do: Application.put_env(:streamix, :tmdb_gindex, gindex),
        else: Application.delete_env(:streamix, :tmdb_gindex)
    end)

    :ok
  end

  describe "enabled?/1 per profile" do
    test "default profile enabled when top-level config has a token" do
      Application.put_env(:streamix, :tmdb, enabled: true, api_token: "default-token")
      Application.delete_env(:streamix, :tmdb_gindex)

      assert TmdbClient.enabled?()
      assert TmdbClient.enabled?(:default)
    end

    test "unknown profile falls back to default config" do
      Application.put_env(:streamix, :tmdb, enabled: true, api_token: "default-token")
      Application.delete_env(:streamix, :tmdb_gindex)

      # No :tmdb_gindex set → inherits default, so it's still enabled.
      assert TmdbClient.enabled?(:gindex)
    end

    test "profile overrides default api_token" do
      Application.put_env(:streamix, :tmdb, enabled: true, api_token: "default-token")

      Application.put_env(:streamix, :tmdb_gindex,
        enabled: true,
        api_token: "gindex-specific-token"
      )

      assert TmdbClient.enabled?(:default)
      assert TmdbClient.enabled?(:gindex)
    end

    test "profile can disable itself even when default is enabled" do
      Application.put_env(:streamix, :tmdb, enabled: true, api_token: "default-token")
      Application.put_env(:streamix, :tmdb_gindex, enabled: false)

      assert TmdbClient.enabled?(:default)
      refute TmdbClient.enabled?(:gindex)
    end

    test "disabled when no token anywhere" do
      Application.put_env(:streamix, :tmdb, enabled: false)
      Application.delete_env(:streamix, :tmdb_gindex)

      refute TmdbClient.enabled?()
      refute TmdbClient.enabled?(:gindex)
    end
  end

  describe "get_movie/2 profile gating" do
    test "returns :tmdb_not_configured when the resolved profile has no token" do
      Application.put_env(:streamix, :tmdb, enabled: false)
      Application.delete_env(:streamix, :tmdb_gindex)

      assert {:error, :tmdb_not_configured} = TmdbClient.get_movie("123", profile: :gindex)
    end
  end
end
