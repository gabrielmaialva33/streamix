defmodule Streamix.AI.UserAnalytics.PersonalizedContentTest do
  use Streamix.DataCase, async: true

  import Streamix.AccountsFixtures
  import Streamix.IptvFixtures

  alias Streamix.AI.UserAnalytics.PersonalizedContent
  alias Streamix.Iptv.Genre

  setup do
    genre = Repo.insert!(%Genre{name: "Terror", slug: "terror"})
    %{key: library_key_fixture(user_fixture()), provider: global_provider_fixture(), genre: genre}
  end

  test "movie eligibility precedes the candidate window", %{
    key: key,
    provider: provider,
    genre: genre
  } do
    for rating <- ["10.0", "9.0"] do
      movie_fixture(provider, %{
        stream_icon: "https://example.com/poster.jpg",
        year: Date.utc_today().year,
        rating: Decimal.new(rating)
      })
    end

    target =
      movie_fixture(provider, %{
        stream_icon: "https://example.com/poster.jpg",
        year: Date.utc_today().year,
        rating: Decimal.new("1.0")
      })

    Repo.insert_all("movie_genres", [%{movie_id: target.id, genre_id: genre.id}])

    assert [%{id: id}] =
             PersonalizedContent.get_personalized_trending(key,
               genre: "terror",
               limit: 1,
               profile: %{},
               insights: %{}
             )

    assert id == target.id
  end

  test "series eligibility precedes the candidate window", %{
    key: key,
    provider: provider,
    genre: genre
  } do
    for rating <- ["10.0", "9.0"] do
      series_content_fixture(provider, %{
        cover: "https://example.com/poster.jpg",
        rating: Decimal.new(rating)
      })
    end

    target =
      series_content_fixture(provider, %{
        cover: "https://example.com/poster.jpg",
        rating: Decimal.new("1.0")
      })

    Repo.insert_all("series_genres", [%{series_id: target.id, genre_id: genre.id}])

    assert [%{id: id}] =
             PersonalizedContent.get_personalized_series(key,
               genre: "terror",
               limit: 1,
               profile: %{},
               insights: %{}
             )

    assert id == target.id
  end
end
