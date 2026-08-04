defmodule StreamixWeb.Api.V1.RecommendationsControllerTest do
  use StreamixWeb.ConnCase, async: false

  import Streamix.AccountsFixtures
  import Streamix.IptvFixtures

  alias Streamix.{Accounts, Billing}

  setup do
    original_api_keys = Application.get_env(:streamix, :api_keys, [])
    Application.put_env(:streamix, :api_keys, [])
    on_exit(fn -> Application.put_env(:streamix, :api_keys, original_api_keys) end)
    :ok
  end

  test "channel recommendations serialize category data without crashing", %{conn: conn} do
    user = user_fixture()
    provider = provider_fixture(user)
    channel = channel_fixture(provider)
    grant_ai_recommendations!(user)

    response =
      conn
      |> authenticated(user)
      |> get(~p"/api/v1/recommendations/channels")
      |> json_response(200)

    assert [%{"id" => id, "category" => nil, "categories" => []}] = response["channels"]
    assert id == channel.id
  end

  defp grant_ai_recommendations!(user) do
    unique = System.unique_integer([:positive])

    {:ok, plan} =
      Billing.create_plan(%{
        name: "AI #{unique}",
        slug: "ai-#{unique}",
        price_cents: 0,
        currency: "BRL",
        billing_interval: "month",
        features: %{"ai_recommendations" => true}
      })

    {:ok, _subscription} =
      Billing.create_manual_subscription(user, plan, %{
        status: "active",
        starts_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })
  end

  defp authenticated(conn, user) do
    token = Accounts.generate_user_session_token(user)
    put_req_header(conn, "authorization", "Bearer #{Base.url_encode64(token)}")
  end
end
