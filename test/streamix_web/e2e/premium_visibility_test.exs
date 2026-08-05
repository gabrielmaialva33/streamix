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
  @playwright_browser (case System.get_env("PLAYWRIGHT_BROWSER") do
                         "chromium" -> :chromium
                         "firefox" -> :firefox
                         "webkit" -> :webkit
                         _ -> :chromium
                       end)

  use PhoenixTest.Playwright.Case, async: false, browser: @playwright_browser
  use StreamixWeb, :verified_routes

  @moduletag :playwright

  setup {StreamixWeb.PlaywrightSupport, :register_context_cleanup}

  import Streamix.AccountsFixtures
  import Streamix.IptvFixtures
  import Phoenix.ConnTest, only: [build_conn: 0, get: 2]
  import StreamixWeb.ConnCase, only: [log_in_user: 2]

  alias PlaywrightEx.BrowserContext
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

  # Premium visibility is the behavior under test. Authenticate through the
  # same signed session cookie as ConnCase so browser-specific form timing
  # cannot make this suite flaky.
  defp login(session, user) do
    cookie =
      build_conn()
      |> log_in_user(user)
      |> get(~p"/browse/movies")
      |> Map.fetch!(:resp_cookies)
      |> Map.fetch!("_streamix_key")

    session
    |> PhoenixTest.Playwright.unwrap(fn %{context_id: context_id} ->
      {:ok, _} =
        BrowserContext.add_cookies(context_id,
          timeout: 5_000,
          cookies: [
            %{
              "name" => "_streamix_key",
              "value" => cookie.value,
              "url" => StreamixWeb.Endpoint.url(),
              "httpOnly" => true,
              "sameSite" => "Lax"
            }
          ]
        )
    end)
    |> visit(~p"/browse/movies")
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
