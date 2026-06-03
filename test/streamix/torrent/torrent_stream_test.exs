defmodule Streamix.Torrent.TorrentStreamTest do
  use Streamix.DataCase, async: true

  alias Streamix.Torrent.TorrentStream

  describe "changeset/2" do
    test "downcases the info_hash and accepts a 40-char hex" do
      hash = String.duplicate("AB12", 10)

      changeset =
        TorrentStream.changeset(%TorrentStream{}, %{
          info_hash: hash,
          magnet_uri: "magnet:?xt=urn:btih:#{hash}",
          source_slug: "yts",
          movie_id: 1
        })

      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :info_hash) == String.downcase(hash)
    end

    test "rejects info_hash with the wrong length or non-hex chars" do
      base = %{magnet_uri: "magnet:?xt=urn:btih:x", source_slug: "yts", movie_id: 1}

      for bad <- ["short", "ZZ" <> String.duplicate("a", 38), String.duplicate("a", 39)] do
        changeset = TorrentStream.changeset(%TorrentStream{}, Map.put(base, :info_hash, bad))
        refute changeset.valid?, "expected #{inspect(bad)} to be rejected"
        assert Keyword.has_key?(changeset.errors, :info_hash)
      end
    end

    test "requires either movie_id or episode_id" do
      changeset =
        TorrentStream.changeset(%TorrentStream{}, %{
          info_hash: String.duplicate("a", 40),
          magnet_uri: "magnet:?xt=urn:btih:x",
          source_slug: "yts"
        })

      refute changeset.valid?
      assert {"either movie_id or episode_id is required", _} = changeset.errors[:movie_id]
    end

    test "rejects unknown quality strings" do
      changeset =
        TorrentStream.changeset(%TorrentStream{}, %{
          info_hash: String.duplicate("a", 40),
          magnet_uri: "magnet:?xt=urn:btih:x",
          source_slug: "yts",
          movie_id: 1,
          quality: "8K"
        })

      refute changeset.valid?
      assert {"unknown quality", _} = changeset.errors[:quality]
    end

    test "accepts the canonical quality tiers" do
      for q <- ~w(480p 720p 1080p 2160p) do
        changeset =
          TorrentStream.changeset(%TorrentStream{}, %{
            info_hash: String.duplicate("a", 40),
            magnet_uri: "magnet:?xt=urn:btih:x",
            source_slug: "yts",
            movie_id: 1,
            quality: q
          })

        assert changeset.valid?, "expected #{q} to be accepted, got #{inspect(changeset.errors)}"
      end
    end
  end
end
