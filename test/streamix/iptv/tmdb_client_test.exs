defmodule Streamix.Iptv.TmdbClientTest do
  use ExUnit.Case, async: false

  alias Streamix.Iptv.TmdbClient
  alias Streamix.Iptv.TmdbClient.Config

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

  describe "profile_from/1" do
    test "accepts only configured profiles and falls back safely" do
      assert Config.profile_from(profile: :gindex) == :gindex
      assert Config.profile_from(%{profile: :gindex}) == :gindex
      assert Config.profile_from(profile: :unknown) == :default
      assert Config.profile_from(%{profile: "gindex"}) == :default
      assert Config.profile_from(:invalid) == :default
    end
  end

  describe "get_movie/2 profile gating" do
    test "returns :tmdb_not_configured when the resolved profile has no token" do
      Application.put_env(:streamix, :tmdb, enabled: false)
      Application.delete_env(:streamix, :tmdb_gindex)

      assert {:error, :tmdb_not_configured} = TmdbClient.get_movie("123", profile: :gindex)
    end
  end

  describe "parse_movie_response/1 — backdrop/poster gallery" do
    # Regression: the gallery backdrops used to land in the generic
    # "image" bucket, so `backdrop_urls` returned only the primary one
    # and hero banners looked identical across every movie.
    test "primary + gallery backdrops are merged into :_backdrop_urls" do
      data = %{
        "id" => 1,
        "backdrop_path" => "/primary.jpg",
        "images" => %{
          "backdrops" => [
            %{"file_path" => "/g1.jpg"},
            %{"file_path" => "/g2.jpg"},
            %{"file_path" => "/g3.jpg"}
          ],
          "posters" => [%{"file_path" => "/p1.jpg"}]
        }
      }

      attrs = TmdbClient.parse_movie_response(data)

      backdrops = attrs[:_backdrop_urls]
      assert is_list(backdrops)
      # Primary first, then gallery — every entry a distinct URL.
      assert length(backdrops) == 4
      assert hd(backdrops) =~ "/primary.jpg"
      assert Enum.uniq(backdrops) == backdrops
    end

    test "gallery posters land in :_image_urls, not mixed with backdrops" do
      data = %{
        "id" => 2,
        "backdrop_path" => "/primary.jpg",
        "images" => %{
          "backdrops" => [%{"file_path" => "/bg1.jpg"}],
          "posters" => [
            %{"file_path" => "/poster1.jpg"},
            %{"file_path" => "/poster2.jpg"}
          ]
        }
      }

      attrs = TmdbClient.parse_movie_response(data)

      posters = attrs[:_image_urls]
      assert length(posters) == 2
      refute Enum.any?(posters, &String.contains?(&1, "primary.jpg"))
      refute Enum.any?(attrs[:_backdrop_urls], &String.contains?(&1, "poster"))
    end

    test "dedups when the primary backdrop also appears in the gallery" do
      data = %{
        "id" => 3,
        "backdrop_path" => "/same.jpg",
        "images" => %{
          "backdrops" => [%{"file_path" => "/same.jpg"}, %{"file_path" => "/other.jpg"}],
          "posters" => []
        }
      }

      attrs = TmdbClient.parse_movie_response(data)
      assert length(attrs[:_backdrop_urls]) == 2
    end

    test "omits _image_urls when the gallery has no posters" do
      data = %{
        "id" => 4,
        "backdrop_path" => "/b.jpg",
        "images" => %{"backdrops" => [], "posters" => []}
      }

      refute Map.has_key?(TmdbClient.parse_movie_response(data), :_image_urls)
    end

    test "still works when TMDB omits the images block" do
      data = %{"id" => 5, "backdrop_path" => "/b.jpg"}
      attrs = TmdbClient.parse_movie_response(data)
      assert length(attrs[:_backdrop_urls]) == 1
      refute Map.has_key?(attrs, :_image_urls)
    end
  end
end
