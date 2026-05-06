defmodule Streamix.Iptv.Sync.NormalizersTest do
  use ExUnit.Case, async: true

  alias Streamix.Iptv.Sync.Normalizers.LiveChannel
  alias Streamix.Iptv.Sync.Normalizers.Movie

  @provider_id 42
  @now ~U[2026-05-06 08:30:00Z]

  describe "Movie.attrs/3" do
    test "defaults missing names to Unknown" do
      attrs = Movie.attrs(%{"stream_id" => 10, "name" => nil}, @provider_id, @now)

      assert attrs.name == "Unknown"
      assert attrs.stream_id == 10
      assert attrs.provider_id == @provider_id
      assert attrs.inserted_at == @now
      assert attrs.updated_at == @now
    end

    test "normalizes invalid year and rating to nil" do
      attrs =
        Movie.attrs(
          %{"stream_id" => 10, "year" => "not-a-year", "rating" => "not-a-rating"},
          @provider_id,
          @now
        )

      assert attrs.year == nil
      assert attrs.rating == nil
    end

    test "normalizes valid year and rating values" do
      attrs = Movie.attrs(%{"year" => "2024", "rating" => "8.7"}, @provider_id, @now)

      assert attrs.year == 2024
      assert Decimal.compare(attrs.rating, Decimal.new("8.7")) == :eq
    end

    test "normalizes tmdb_id integers, strings, and nils" do
      assert Movie.attrs(%{"tmdb_id" => 123_456}, @provider_id, @now).tmdb_id == "123456"
      assert Movie.attrs(%{"tmdb_id" => "98765"}, @provider_id, @now).tmdb_id == "98765"
      assert Movie.attrs(%{"tmdb_id" => nil}, @provider_id, @now).tmdb_id == nil
    end
  end

  describe "LiveChannel.attrs/3" do
    test "normalizes tv_archive integer 1 as enabled" do
      attrs = LiveChannel.attrs(%{"stream_id" => 20, "tv_archive" => 1}, @provider_id, @now)

      assert attrs.tv_archive == true
      assert attrs.stream_id == 20
      assert attrs.provider_id == @provider_id
      assert attrs.inserted_at == @now
      assert attrs.updated_at == @now
    end

    test "preserves current tv_archive string 1 behavior as disabled" do
      attrs = LiveChannel.attrs(%{"tv_archive" => "1"}, @provider_id, @now)

      assert attrs.tv_archive == false
    end

    test "resets dead_since while normalizing upstream channel attrs" do
      attrs =
        LiveChannel.attrs(
          %{
            "name" => "Recovered Channel",
            "dead_since" => ~U[2026-05-01 10:00:00Z],
            "tv_archive" => 0
          },
          @provider_id,
          @now
        )

      assert attrs.name == "Recovered Channel"
      assert attrs.dead_since == nil
    end
  end
end
