defmodule Streamix.AI.UserAnalyticsTest do
  use Streamix.DataCase, async: false

  import ExUnit.CaptureLog
  import Streamix.AccountsFixtures
  import Streamix.IptvFixtures

  alias Streamix.AI.UserAnalytics
  alias Streamix.AI.UserAnalytics.{Filters, Indexing, Insights, Profile, Recommendations}
  alias Streamix.Iptv.{Category, Genre, History, WatchProgress}

  defmodule ProfileQdrantStub do
    def get_points(_collection, ids) do
      {:ok, Enum.map(ids, &%{id: &1, vector: [0.25, 0.75], payload: %{}})}
    end

    def upsert_point(_collection, _id, _vector, _payload) do
      Application.fetch_env!(:streamix, :user_profile_qdrant_result)
    end
  end

  setup do
    original_nvidia = Application.get_env(:streamix, :nvidia)
    original_gemini = Application.get_env(:streamix, :gemini)
    original_embeddings = Application.get_env(:streamix, :embeddings)

    Application.put_env(:streamix, :nvidia, put_config(original_nvidia, :api_key, ""))
    Application.put_env(:streamix, :gemini, put_config(original_gemini, :api_key, ""))

    Application.put_env(
      :streamix,
      :embeddings,
      put_config(original_embeddings, :provider, "nvidia")
    )

    on_exit(fn ->
      restore_env(:nvidia, original_nvidia)
      restore_env(:gemini, original_gemini)
      restore_env(:embeddings, original_embeddings)
    end)
  end

  describe "filter facade" do
    test "returns deterministic defaults for anonymous users and static filter groups" do
      assert UserAnalytics.get_user_genre_filters(nil) == Filters.get_user_genre_filters(nil)

      assert UserAnalytics.get_user_genre_filters(nil) == [
               {"all", "Todos"},
               {"action", "Ação"},
               {"comedy", "Comédia"},
               {"drama", "Drama"},
               {"horror", "Terror"},
               {"sci-fi", "Ficção"},
               {"animation", "Animação"}
             ]

      assert UserAnalytics.get_period_filters() == [
               {7, "7 dias"},
               {30, "30 dias"},
               {nil, "Todos"}
             ]

      assert UserAnalytics.get_channel_category_filters() == [
               {"all", "Todos"},
               {"sports", "Esportes"},
               {"movies", "Filmes"},
               {"news", "Notícias"},
               {"kids", "Infantil"}
             ]
    end

    test "uses the user's top watched movie genres when insight data exists" do
      user = user_fixture()
      provider = provider_fixture(user)

      action = genre_fixture("Action")
      drama = genre_fixture("Drama")
      comedy = genre_fixture("Comedy")

      action_one =
        provider
        |> movie_fixture(%{name: "Action One"})
        |> attach_genres([action])

      action_two =
        provider
        |> movie_fixture(%{name: "Action Two"})
        |> attach_genres([action])

      action_three =
        provider
        |> movie_fixture(%{name: "Action Three"})
        |> attach_genres([action])

      drama_one =
        provider
        |> movie_fixture(%{name: "Drama One"})
        |> attach_genres([drama])

      drama_two =
        provider
        |> movie_fixture(%{name: "Drama Two"})
        |> attach_genres([drama])

      comedy_one =
        provider
        |> movie_fixture(%{name: "Comedy One"})
        |> attach_genres([comedy])

      watched_movie(user, action_one)
      watched_movie(user, action_two)
      watched_movie(user, action_three)
      watched_movie(user, drama_one)
      watched_movie(user, drama_two)
      watched_movie(user, comedy_one)

      assert [
               {"all", "Todos"},
               {"action", "Action"},
               {"drama", "Drama"},
               {"comedy", "Comedy"},
               {"more", "Mais..."}
             ] = UserAnalytics.get_user_genre_filters(user.id)
    end
  end

  describe "insights facade" do
    test "returns no-data contract for users without history" do
      user = user_fixture()

      assert UserAnalytics.get_user_insights(user.id) == Insights.get_user_insights(user.id)
      assert UserAnalytics.get_user_insights(user.id) == %{has_data: false}
    end

    test "summarizes completion, genre, type, time, and session patterns" do
      user = user_fixture()
      provider = provider_fixture(user)
      action = genre_fixture("Action")
      drama = genre_fixture("Drama")

      saturday_night = DateTime.new!(~D[2026-05-02], ~T[21:00:00], "Etc/UTC")
      saturday_later = DateTime.new!(~D[2026-05-02], ~T[21:30:00], "Etc/UTC")
      tuesday_morning = DateTime.new!(~D[2026-05-05], ~T[10:00:00], "Etc/UTC")

      action_movie =
        provider
        |> movie_fixture(%{name: "Completed Action"})
        |> attach_genres([action])

      drama_movie =
        provider
        |> movie_fixture(%{name: "Partial Drama"})
        |> attach_genres([drama])

      channel = channel_fixture(provider, %{name: "Weekend Channel"})

      watched_movie(user, action_movie, %{
        completed: true,
        duration_seconds: 7200,
        watched_at: saturday_night
      })

      watched_movie(user, drama_movie, %{
        completed: false,
        duration_seconds: 1800,
        watched_at: saturday_later
      })

      watched_channel(user, channel, %{
        completed: false,
        duration_seconds: 600,
        watched_at: tuesday_morning
      })

      insights = UserAnalytics.get_user_insights(user.id)

      assert insights.has_data == true
      assert insights.total_items == 3
      assert insights.content_breakdown == %{"live_channel" => 1, "movie" => 2}
      assert insights.completion_rate == 33.3
      assert insights.favorite_genres == ["Action", "Drama"]

      assert insights.watch_patterns == %{
               peak_hour: 21,
               weekend_preference: true,
               weekday_count: 1,
               weekend_count: 2
             }

      assert insights.most_watched_day == "Sábado"
      assert insights.avg_session_length == 53
    end
  end

  describe "profile facade" do
    test "compute_user_profile returns a deterministic no-history error without Qdrant" do
      user = user_fixture()

      assert UserAnalytics.compute_user_profile(user.id) == Profile.compute_user_profile(user.id)
      assert UserAnalytics.compute_user_profile(user.id) == {:error, :no_history}
    end

    test "get_user_profile returns cached profile vectors without external lookup" do
      user = user_fixture()
      vector = [0.1, 0.2, 0.7]

      put_l1_cache("user_profile:#{user.id}", vector)

      assert UserAnalytics.get_user_profile(user.id) == Profile.get_user_profile(user.id)
      assert UserAnalytics.get_user_profile(user.id) == vector
    end

    test "returns persistence failures so callers can retry profile updates" do
      user = user_fixture()
      provider = provider_fixture(user)
      movie = movie_fixture(provider, %{name: "Profile Persistence"})
      watched_movie(user, movie)

      previous_module = Application.get_env(:streamix, :user_profile_qdrant_module)
      previous_result = Application.get_env(:streamix, :user_profile_qdrant_result)

      Application.put_env(:streamix, :user_profile_qdrant_module, ProfileQdrantStub)
      Application.put_env(:streamix, :user_profile_qdrant_result, {:error, :unavailable})

      on_exit(fn ->
        restore_env(:user_profile_qdrant_module, previous_module)
        restore_env(:user_profile_qdrant_result, previous_result)
      end)

      assert UserAnalytics.compute_user_profile(user.id) ==
               {:error, {:profile_store_failed, :unavailable}}
    end
  end

  describe "recommendation facade" do
    test "get_recommendations honors cached facade results without Qdrant search" do
      user = user_fixture()

      cached = [
        %{
          id: 101,
          score: 0.987,
          title: "Cached Choice",
          year: 2026,
          genre: "Drama",
          rating: "9.1"
        }
      ]

      put_l1_cache("recommendations:#{user.id}:movies:1", cached)

      assert UserAnalytics.get_recommendations(user.id, type: "movies", limit: 1) ==
               Recommendations.get_recommendations(user.id, type: "movies", limit: 1)

      assert UserAnalytics.get_recommendations(user.id, type: "movies", limit: 1) == cached
    end

    test "get_more_like_this returns the embedding failure without searching Qdrant" do
      user = user_fixture()
      provider = provider_fixture(user)
      movie = movie_fixture(provider, %{name: "No Embedding Movie", plot: "Local only"})

      capture_log(fn ->
        assert UserAnalytics.get_more_like_this(movie, "movies") ==
                 Recommendations.get_more_like_this(movie, "movies")

        assert UserAnalytics.get_more_like_this(movie, "movies") == {:error, :not_configured}
      end)
    end

    test "channel recommendations fall back to public popular channels for new users" do
      user = user_fixture()
      owner = user_fixture()

      global_provider = provider_fixture(owner, %{visibility: :global, is_system: true})
      private_provider = provider_fixture(owner, %{visibility: :private})

      global_channel =
        channel_fixture(global_provider, %{
          name: "A Global Channel",
          stream_icon: "http://example.com/global.png"
        })

      _private_channel =
        channel_fixture(private_provider, %{
          name: "Private Channel",
          stream_icon: "http://example.com/private.png"
        })

      assert {:ok, channels} = UserAnalytics.get_channel_recommendations(user.id, limit: 5)
      assert Enum.map(channels, & &1.id) == [global_channel.id]
    end

    test "personalized channel category filter returns matching public channels first" do
      user = user_fixture()
      owner = user_fixture()
      provider = provider_fixture(owner, %{visibility: :global, is_system: true})

      sports = category_fixture(provider, %{name: "Sports Premium", external_id: "sports"})
      news = category_fixture(provider, %{name: "News Live", external_id: "news"})

      sports_channel =
        provider
        |> channel_fixture(%{name: "Sports Alpha", stream_icon: "http://example.com/sports.png"})
        |> attach_category(sports)

      provider
      |> channel_fixture(%{name: "News Alpha", stream_icon: "http://example.com/news.png"})
      |> attach_category(news)

      assert [channel] =
               UserAnalytics.get_personalized_channels(user.id, category: "sports", limit: 5)

      assert channel.id == sports_channel.id
    end
  end

  describe "indexing facade" do
    test "index_content returns embedding errors without attempting vector upsert" do
      user = user_fixture()
      provider = provider_fixture(user)
      movie = movie_fixture(provider, %{name: "Indexing Contract", plot: "No external embedding"})

      capture_log(fn ->
        assert UserAnalytics.index_content(movie, "movies") ==
                 Indexing.index_content(movie, "movies")

        assert UserAnalytics.index_content(movie, "movies") == {:error, :not_configured}
      end)
    end

    test "index_contents returns batch embedding errors without attempting vector upsert" do
      user = user_fixture()
      provider = provider_fixture(user)
      movie = movie_fixture(provider, %{name: "Batch Indexing Contract"})

      capture_log(fn ->
        assert UserAnalytics.index_contents([movie], "movies") ==
                 Indexing.index_contents([movie], "movies")

        assert UserAnalytics.index_contents([movie], "movies") == {:error, :not_configured}
      end)
    end
  end

  defp watched_movie(user, movie, attrs \\ %{}) do
    watched_at = Map.get(attrs, :watched_at, DateTime.utc_now() |> DateTime.truncate(:second))

    {:ok, _history} =
      History.add(user.id, "movie", movie.id, Map.drop(attrs, [:watched_at]))

    set_watched_at(user.id, movie.catalog_item_id, watched_at)
    movie
  end

  defp watched_channel(user, channel, attrs) do
    watched_at = Map.fetch!(attrs, :watched_at)

    {:ok, _history} =
      History.add(user.id, "live_channel", channel.id, Map.drop(attrs, [:watched_at]))

    set_watched_at(user.id, channel.catalog_item_id, watched_at)
    channel
  end

  defp set_watched_at(user_id, catalog_item_id, watched_at) do
    from(progress in WatchProgress,
      where: progress.user_id == ^user_id and progress.catalog_item_id == ^catalog_item_id
    )
    |> Repo.update_all(set: [last_watched_at: DateTime.truncate(watched_at, :second)])
  end

  defp genre_fixture(name) do
    %Genre{}
    |> Genre.changeset(%{name: name})
    |> Repo.insert!()
  end

  defp attach_genres(movie, genres) do
    rows = Enum.map(genres, &%{movie_id: movie.id, genre_id: &1.id})
    Repo.insert_all("movie_genres", rows)
    movie
  end

  defp category_fixture(provider, attrs) do
    attrs =
      Enum.into(attrs, %{
        provider_id: provider.id,
        type: "live",
        is_adult: false
      })

    %Category{}
    |> Category.changeset(attrs)
    |> Repo.insert!()
  end

  defp attach_category(channel, category) do
    Repo.insert_all("item_categories", [
      %{catalog_item_id: channel.catalog_item_id, category_id: category.id}
    ])

    channel
  end

  defp put_l1_cache(key, value) do
    ConCache.put(
      :streamix_l1_cache,
      key,
      %ConCache.Item{value: value, ttl: :timer.seconds(60)}
    )

    on_exit(fn -> ConCache.delete(:streamix_l1_cache, key) end)
  end

  defp put_config(nil, key, value), do: [{key, value}]
  defp put_config(config, key, value), do: Keyword.put(config, key, value)

  defp restore_env(key, nil), do: Application.delete_env(:streamix, key)
  defp restore_env(key, value), do: Application.put_env(:streamix, key, value)
end
