defmodule Streamix.Gindex.EndpointManagerTest do
  use ExUnit.Case, async: false

  alias Streamix.Gindex.EndpointManager

  setup do
    original_config = Application.get_env(:streamix, :gindex_provider)

    on_exit(fn ->
      if original_config,
        do: Application.put_env(:streamix, :gindex_provider, original_config),
        else: Application.delete_env(:streamix, :gindex_provider)
    end)

    :ok
  end

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

  test "keeps configured single URL as primary when adding default fallbacks" do
    Application.put_env(:streamix, :gindex_provider,
      enabled: true,
      url: "https://1.animezeydl.workers.dev/"
    )

    pid =
      start_supervised!(
        {EndpointManager,
         name: :gindex_endpoint_manager_single_url_test,
         table_name: :gindex_endpoints_single_url_test}
      )

    assert {:ok, configured_endpoints} = GenServer.call(pid, :get_all_endpoints)

    assert [
             %{
               name: :primary,
               url: "https://1.animezeydl.workers.dev/",
               priority: 1
             },
             %{
               name: :animezey_legacy,
               url: "https://animezey16082023.animezey16082023.workers.dev",
               priority: 2
             }
           ] = configured_endpoints
  end

  test "uses the verified two-Worker pool by default" do
    Application.put_env(:streamix, :gindex_provider, enabled: true)

    pid =
      start_supervised!(
        {EndpointManager,
         name: :gindex_endpoint_manager_defaults_test, table_name: :gindex_endpoints_defaults_test}
      )

    assert {:ok, configured_endpoints} = GenServer.call(pid, :get_all_endpoints)

    assert [
             %{
               name: :animezeydl,
               url: "https://1.animezeydl.workers.dev",
               priority: 1
             },
             %{
               name: :animezey_legacy,
               url: "https://animezey16082023.animezey16082023.workers.dev",
               priority: 2
             }
           ] = configured_endpoints
  end
end
