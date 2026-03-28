defmodule Streamix.Iptv.Gindex.EndpointManagerTest do
  use ExUnit.Case, async: false

  alias Streamix.Iptv.Gindex.EndpointManager

  test "builds configured endpoint lists without creating dynamic atoms" do
    endpoints = [
      "https://one.example.com",
      "https://two.example.com"
    ]

    pid =
      start_supervised!(
        {EndpointManager,
         name: :gindex_endpoint_manager_test,
         table_name: :gindex_endpoints_test,
         endpoints: endpoints}
      )

    assert {:ok, configured_endpoints} = GenServer.call(pid, :get_all_endpoints)

    assert [
             %{name: "endpoint_1", url: "https://one.example.com", priority: 1},
             %{name: "endpoint_2", url: "https://two.example.com", priority: 2}
           ] = configured_endpoints

    assert_raise ArgumentError, fn ->
      :erlang.binary_to_existing_atom("endpoint_1")
    end
  end
end
