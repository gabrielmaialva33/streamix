defmodule StreamixWeb.StreamTokenTest do
  use Streamix.DataCase, async: false

  import Streamix.AccountsFixtures
  import Streamix.IptvFixtures

  alias Streamix.Billing.Plan
  alias Streamix.Billing.Subscription
  alias Streamix.Iptv.{Episode, Season}
  alias Streamix.Repo
  alias StreamixWeb.StreamToken

  defp plan_fixture(attrs \\ %{}) do
    params =
      Enum.into(attrs, %{
        name: "Premium",
        slug: "premium-#{System.unique_integer([:positive])}",
        description: "Acesso global ao catálogo e recursos premium.",
        price_cents: 1_999,
        currency: "BRL",
        billing_interval: "month",
        active: true,
        grants_global_access: true
      })

    %Plan{}
    |> Plan.changeset(params)
    |> Repo.insert!()
  end

  defp subscription_fixture(user, plan, attrs \\ %{}) do
    params =
      Enum.into(attrs, %{
        status: "active",
        starts_at: DateTime.utc_now(),
        expires_at: nil,
        canceled_at: nil,
        source: "stripe",
        external_reference: "sub_test_#{System.unique_integer([:positive])}"
      })

    %Subscription{}
    |> Subscription.create_changeset(user, plan, params)
    |> Repo.insert!()
  end

  test "global content still verifies for subscribed user" do
    user = user_fixture()
    plan = plan_fixture()
    _subscription = subscription_fixture(user, plan)

    provider =
      provider_fixture(user, %{
        visibility: "global",
        is_system: true
      })

    movie = movie_fixture(provider, %{stream_id: 123_456})
    token = StreamToken.sign_movie(movie.id, user.id)

    assert {:ok, url, "movie", %{content_id: content_id}} = StreamToken.verify_and_get_url(token)
    assert content_id == movie.id
    assert url =~ "/movie/#{provider.username}/#{provider.password}/#{movie.stream_id}.mp4"
  end

  test "public and private owned content still verifies without subscription" do
    owner = user_fixture()

    for visibility <- ["public", "private"] do
      provider =
        provider_fixture(owner, %{
          visibility: visibility,
          is_system: false
        })

      movie = movie_fixture(provider, %{stream_id: System.unique_integer([:positive])})
      token = StreamToken.sign_movie(movie.id, owner.id)

      assert {:ok, url, "movie", %{content_id: content_id}} =
               StreamToken.verify_and_get_url(token)

      assert content_id == movie.id
      assert url =~ "/movie/#{provider.username}/#{provider.password}/#{movie.stream_id}.mp4"
    end
  end

  test "torrent movies cannot enter the Xtream stream-token pipeline" do
    owner = user_fixture()

    provider =
      provider_fixture(owner, %{
        visibility: "private",
        is_system: false,
        provider_type: "torrent",
        url: "torrent://aggregator",
        username: nil,
        password: nil
      })

    movie = movie_fixture(provider)
    token = StreamToken.sign_movie(movie.id, owner.id)

    assert {:error, :torrent_playback_required} = StreamToken.verify_and_get_url(token)

    assert {:error, :torrent_playback_required} =
             StreamToken.upstream_url("movie", movie.id, owner.id)
  end

  describe "global content entitlement" do
    setup do
      owner = user_fixture()

      provider =
        provider_fixture(owner, %{
          visibility: "global",
          is_system: true,
          provider_type: "xtream",
          is_active: true
        })

      series = series_content_fixture(provider, %{name: "Serie Global"})

      season =
        %Season{}
        |> Season.changeset(%{season_number: 1, name: "T1", series_id: series.id})
        |> Repo.insert!()

      catalog_item = catalog_item_fixture("episode", provider.id)

      episode =
        %Episode{}
        |> Episode.changeset(%{
          episode_id: System.unique_integer([:positive]),
          episode_num: 1,
          title: "S01E01",
          container_extension: "mp4",
          season_id: season.id
        })
        |> Ecto.Changeset.put_change(:catalog_item_id, catalog_item.id)
        |> Repo.insert!()

      %{provider: provider, episode: episode}
    end

    test "an episode token is refused without a subscription", %{episode: episode} do
      # An Episode has no provider_id and no provider association, so gating on
      # the content struct made Access.global_content?/1 fall through to false
      # and let every user through. The gate has to take the provider.
      viewer = user_fixture()
      token = StreamToken.sign_episode(episode.id, viewer.id)

      assert {:error, :subscription_required} = StreamToken.verify_and_get_url(token)
    end

    test "an episode token resolves for a subscriber", %{episode: episode} do
      viewer = user_fixture()
      subscription_fixture(viewer, plan_fixture())

      token = StreamToken.sign_episode(episode.id, viewer.id)

      assert {:ok, url, "episode", _meta} = StreamToken.verify_and_get_url(token)
      assert url =~ "/series/"
    end
  end

  test "premium url token without entitlement is rejected" do
    user = user_fixture()

    provider =
      provider_fixture(user, %{
        visibility: "global",
        is_system: true
      })

    token =
      StreamToken.sign_url("http://example.com/video.mp4", user.id,
        premium_required: true,
        provider_id: provider.id
      )

    assert {:error, :subscription_required} = StreamToken.verify_and_get_url(token)
  end

  test "private url token requires the provider owner" do
    owner = user_fixture()
    other_user = user_fixture()

    provider =
      provider_fixture(owner, %{
        visibility: "private",
        is_system: false
      })

    token =
      StreamToken.sign_url("http://example.com/video.mp4", other_user.id,
        provider_id: provider.id
      )

    assert {:error, :unauthorized} = StreamToken.verify_and_get_url(token)
  end

  test "gindex movie token resolves the cached download url instead of xtream path" do
    owner = user_fixture()

    provider =
      provider_fixture(owner, %{
        provider_type: :gindex,
        url: "http://127.0.0.1:65535",
        gindex_url: "http://127.0.0.1:65535",
        username: nil,
        password: nil
      })

    cached_url = "http://cdn.example.test/download/movie.mp4"

    movie =
      movie_fixture(provider, %{
        gindex_path: "/1:/Filmes/movie.mp4"
      })

    :ets.insert(
      :gindex_url_cache,
      {{:movie, movie.id}, cached_url, System.monotonic_time(:millisecond) + :timer.minutes(30)}
    )

    token = StreamToken.sign_movie(movie.id, owner.id)

    assert {:ok, ^cached_url, "movie", %{content_id: content_id, provider_id: provider_id}} =
             StreamToken.verify_and_get_url(token)

    assert content_id == movie.id
    assert provider_id == provider.id
  end
end
