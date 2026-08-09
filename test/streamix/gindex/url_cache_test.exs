defmodule Streamix.Gindex.UrlCacheTest do
  use ExUnit.Case, async: false

  alias Streamix.Gindex.UrlCache

  test "serves a valid cached URL without depending on the cache owner mailbox" do
    movie_id = System.unique_integer([:positive])
    cache_key = {:movie, movie_id}
    url = "https://cdn.example.test/movie.mkv"
    owner = Process.whereis(UrlCache)
    assert is_pid(owner)

    :ets.insert(
      :gindex_url_cache,
      {cache_key, url, System.monotonic_time(:millisecond) + :timer.minutes(30)}
    )

    :ok = :sys.suspend(owner)

    on_exit(fn ->
      if Process.alive?(owner), do: :sys.resume(owner)
      :ets.delete(:gindex_url_cache, cache_key)
    end)

    task = Task.async(fn -> UrlCache.get_movie_url(movie_id) end)
    assert Task.await(task, 100) == {:ok, url}
  end
end
