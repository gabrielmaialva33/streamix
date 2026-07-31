defmodule Streamix.Iptv.ProviderCapabilitiesTest do
  use ExUnit.Case, async: true

  alias Streamix.Iptv.ProviderCapabilities

  test "normalizes the authenticated Xtream account payload" do
    expires_at = DateTime.utc_now() |> DateTime.add(7, :day) |> DateTime.to_unix()

    assert {:ok, capabilities} =
             ProviderCapabilities.from_account_info(%{
               "user_info" => %{
                 "auth" => 1,
                 "status" => "Active",
                 "exp_date" => Integer.to_string(expires_at),
                 "max_connections" => "2",
                 "active_cons" => "1",
                 "allowed_output_formats" => ["TS", "m3u8", "TS"]
               },
               "server_info" => %{"server_protocol" => "https"}
             })

    assert capabilities.authenticated?
    assert capabilities.active?
    assert capabilities.max_connections == 2
    assert capabilities.active_connections == 1
    assert capabilities.allowed_output_formats == ["ts", "m3u8"]
    assert capabilities.server_protocol == "https"
    assert ProviderCapabilities.status(capabilities) == :healthy
  end

  test "fails closed for malformed and inactive account responses" do
    assert {:error, :invalid_account_info} = ProviderCapabilities.from_account_info(%{})

    assert {:ok, capabilities} =
             ProviderCapabilities.from_account_info(%{
               "user_info" => %{
                 "auth" => "0",
                 "status" => "Disabled",
                 "max_connections" => "not-an-integer"
               }
             })

    refute capabilities.authenticated?
    refute capabilities.active?
    assert capabilities.max_connections == 1
    assert ProviderCapabilities.status(capabilities) == :unhealthy
  end

  test "marks accounts close to expiration or at capacity as degraded" do
    expires_at = DateTime.utc_now() |> DateTime.add(2, :day) |> DateTime.to_unix()

    assert {:ok, capabilities} =
             ProviderCapabilities.from_account_info(%{
               "user_info" => %{
                 "auth" => "1",
                 "status" => "Active",
                 "exp_date" => expires_at,
                 "max_connections" => "1",
                 "active_cons" => "1"
               }
             })

    assert ProviderCapabilities.status(capabilities) == :degraded
  end

  test "public view never retains the raw account response" do
    assert {:ok, capabilities} =
             ProviderCapabilities.from_account_info(%{
               "user_info" => %{
                 "auth" => 1,
                 "status" => "Active",
                 "password" => "must-not-escape"
               }
             })

    public = ProviderCapabilities.public(capabilities)

    refute Map.has_key?(public, :password)
    refute inspect(public) =~ "must-not-escape"
  end
end
