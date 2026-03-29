defmodule StreamixWeb.StreamTokenTest do
  use Streamix.DataCase, async: true

  import Streamix.AccountsFixtures
  import Streamix.IptvFixtures

  alias Streamix.Billing.Plan
  alias Streamix.Billing.Subscription
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

    assert {:ok, url, "movie"} = StreamToken.verify_and_get_url(token)
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

      assert {:ok, url, "movie"} = StreamToken.verify_and_get_url(token)
      assert url =~ "/movie/#{provider.username}/#{provider.password}/#{movie.stream_id}.mp4"
    end
  end
end
