defmodule Streamix.Iptv.HistoryTest do
  use Streamix.DataCase, async: true

  alias Streamix.Iptv.History

  import Streamix.AccountsFixtures
  import Streamix.IptvFixtures

  describe "list_for_analytics/2" do
    test "returns lightweight analytics entries without catalog preloads" do
      user = user_fixture()
      provider = provider_fixture(user)

      movie =
        movie_fixture(provider, %{
          name: "Analytics Movie",
          stream_icon: "http://example.com/a.jpg"
        })

      {:ok, _entry} =
        History.add(user.id, "movie", movie.id, %{
          progress_seconds: 50,
          duration_seconds: 100,
          completed: true
        })

      [entry] = History.list_for_analytics(user.id, content_type: "movie", limit: 10)

      assert entry.content_type == "movie"
      assert entry.content_id == movie.id
      assert entry.progress_seconds == 50
      assert entry.duration_seconds == 100
      assert entry.completed == true
      assert %DateTime{} = entry.watched_at
      refute Map.has_key?(entry, :catalog_item)

      assert Map.keys(entry) |> Enum.sort() == [
               :completed,
               :content_id,
               :content_type,
               :duration_seconds,
               :progress_seconds,
               :watched_at
             ]
    end
  end
end
