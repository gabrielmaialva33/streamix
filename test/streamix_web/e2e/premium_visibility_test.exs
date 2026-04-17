defmodule StreamixWeb.E2E.PremiumVisibilityTest do
  @moduledoc """
  End-to-end regression for the premium badge / CTA visibility fix.

  Runs in a real browser via Playwright. Excluded by default — run with:

      mix test --include playwright

  Or target only this file:

      mix test --include playwright test/streamix_web/e2e/premium_visibility_test.exs
  """

  # async: false avoids Bandit connection reuse flakiness across parallel
  # sandboxed tests. If this suite grows, switch back to async: true and
  # tune `ecto_sandbox_stop_owner_delay` or pin Bandit to one handler.
  use PhoenixTest.Playwright.Case, async: false
  use StreamixWeb, :verified_routes

  @moduletag :playwright

  import Streamix.AccountsFixtures
  import Streamix.IptvFixtures

  alias Streamix.Billing.{Plan, Subscription}
  alias Streamix.Repo

  setup do
    # PhoenixTest.Playwright.Case already set up the per-test sandbox and
    # wired the User-Agent header. We just seed fixtures here.
    provider =
      provider_fixture(admin_user_fixture(), %{
        visibility: "global",
        is_system: true,
        provider_type: "xtream",
        is_active: true
      })

    movie_fixture(provider, %{
      name: "Premium Smoke Movie",
      plot: "smoke",
      content_rating: "14"
    })

    :ok
  end

  describe "/browse/movies" do
    test "free user sees premium CTA and badge", %{conn: conn} do
      user = user_fixture()

      conn
      |> login(user)
      |> assert_has("#browse-premium-cta")
      |> assert_has("[data-premium-badge]")
    end

    test "admin does not see premium CTA nor badge", %{conn: conn} do
      admin = admin_user_fixture()

      conn
      |> login(admin)
      |> refute_has("#browse-premium-cta")
      |> refute_has("[data-premium-badge]")
    end

    test "subscribed user does not see premium CTA nor badge", %{conn: conn} do
      user = user_fixture()
      plan = plan_fixture()
      _sub = create_subscription!(user, plan)

      conn
      |> login(user)
      |> refute_has("#browse-premium-cta")
      |> refute_has("[data-premium-badge]")
    end
  end

  # Hit the protected page first so `user_return_to` is stored in the session;
  # after login we land directly on /browse/movies, skipping HomeLive (which
  # uses Task.async_stream and would crash without sandbox in the child tasks).
  defp login(conn, user) do
    conn
    |> visit(~p"/browse/movies")
    # Wait for LoginLive to connect so phx-change/submit handlers are wired.
    |> assert_has("body .phx-connected form[action='/login']")
    |> fill_in("Email", with: user.email)
    |> fill_in("Senha", with: valid_user_password())
    |> submit()
    |> assert_has("#movies")
  end

  defp plan_fixture(attrs \\ %{}) do
    unique = System.unique_integer([:positive])

    params =
      Enum.into(attrs, %{
        name: "Premium #{unique}",
        slug: "premium-#{unique}",
        description: "Access to global content",
        price_cents: 1_999,
        currency: "USD",
        billing_interval: "month",
        active: true,
        grants_global_access: true
      })

    %Plan{}
    |> Plan.changeset(params)
    |> Repo.insert!()
  end

  defp create_subscription!(user, plan, attrs \\ %{}) do
    params =
      Enum.into(attrs, %{
        status: "active",
        starts_at: DateTime.add(DateTime.utc_now(), -1, :day),
        expires_at: DateTime.add(DateTime.utc_now(), 1, :day),
        canceled_at: nil,
        source: "stripe",
        external_reference: "sub_#{System.unique_integer([:positive])}"
      })

    %Subscription{}
    |> Subscription.create_changeset(user, plan, params)
    |> Repo.insert!()
  end
end
