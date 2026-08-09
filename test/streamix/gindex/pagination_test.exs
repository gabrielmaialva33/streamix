defmodule Streamix.Gindex.PaginationTest do
  use ExUnit.Case, async: false

  alias Streamix.Gindex.Pagination

  setup do
    original = Application.get_env(:streamix, Pagination)

    Application.put_env(:streamix, Pagination, delay_ms: 0, jitter_ms: 0)

    on_exit(fn ->
      if original,
        do: Application.put_env(:streamix, Pagination, original),
        else: Application.delete_env(:streamix, Pagination)
    end)

    :ok
  end

  test "restarts the listing when a partial cursor fails on the first endpoint" do
    test_pid = self()

    request_fun = fn :post, _url, body, base_url ->
      %{"page_token" => page_token, "page_index" => page_index} = Jason.decode!(body)
      send(test_pid, {:request, base_url, page_token, page_index})

      case {base_url, page_token} do
        {"https://broken.example", nil} ->
          folder_response(["Filme A"], "next-page")

        {"https://broken.example", "next-page"} ->
          {:ok, %{status: 500, body: "TypeError"}}

        {"https://healthy.example", nil} ->
          folder_response(["Filme A"], "healthy-next-page")

        {"https://healthy.example", "healthy-next-page"} ->
          folder_response(["Filme B"], nil)
      end
    end

    assert {:ok, items} =
             Pagination.list_folder_all(
               ["https://broken.example", "https://healthy.example"],
               "/1:/Filmes/2026/",
               request_fun: request_fun
             )

    assert Enum.map(items, & &1.name) == ["Filme A", "Filme B"]

    assert_receive {:request, "https://broken.example", nil, 0}
    assert_receive {:request, "https://broken.example", "next-page", 1}
    assert_receive {:request, "https://healthy.example", nil, 0}
    assert_receive {:request, "https://healthy.example", "healthy-next-page", 1}
    refute_receive {:request, "https://healthy.example", "next-page", _page_index}
  end

  test "returns an error instead of presenting an incomplete listing as success" do
    request_fun = fn :post, _url, body, base_url ->
      page_token = Jason.decode!(body)["page_token"]

      case {base_url, page_token} do
        {_base_url, nil} ->
          folder_response(["Filme A"], "next-page")

        {_base_url, "next-page"} ->
          {:ok, %{status: 500, body: "TypeError"}}
      end
    end

    assert {:error,
            {:partial_listing,
             %{
               path: "/1:/Filmes/2026/",
               page: 1,
               items: partial_items,
               items_collected: 1,
               reason: {:all_endpoints_failed, failures}
             }}} =
             Pagination.list_folder_all(
               ["https://broken.example", "https://also-broken.example"],
               "/1:/Filmes/2026/",
               request_fun: request_fun
             )

    assert Enum.map(partial_items, & &1.name) == ["Filme A"]

    assert [
             %{
               endpoint: "https://broken.example",
               page: 1,
               items_collected: 1,
               reason: {:http_error, 500}
             },
             %{
               endpoint: "https://also-broken.example",
               page: 1,
               items_collected: 1,
               reason: {:http_error, 500}
             }
           ] = failures
  end

  test "does not fan out a shared quota exhaustion across mirrors" do
    test_pid = self()

    request_fun = fn :post, _url, _body, base_url ->
      send(test_pid, {:request, base_url})
      {:error, {:quota_exhausted, 8_000}}
    end

    assert {:error, {:quota_exhausted, 8_000}} =
             Pagination.list_folder_all(
               ["https://one.example", "https://two.example"],
               "/1:/Filmes/",
               request_fun: request_fun
             )

    assert_receive {:request, "https://one.example"}
    refute_receive {:request, "https://two.example"}
  end

  test "preserves a shared upstream rate limit after checking the endpoint pool" do
    request_fun = fn :post, _url, _body, base_url ->
      retry_after = if base_url == "https://one.example", do: 30, else: 90
      {:error, {:rate_limited, 429, retry_after}}
    end

    assert {:error, {:rate_limited, 429, 90}} =
             Pagination.list_folder_all(
               ["https://one.example", "https://two.example"],
               "/1:/Filmes/",
               request_fun: request_fun
             )
  end

  defp folder_response(names, next_page_token) do
    files =
      Enum.map(names, fn name ->
        %{
          "name" => name,
          "mimeType" => "application/vnd.google-apps.folder"
        }
      end)

    {:ok,
     %{
       status: 200,
       body: %{"data" => %{"files" => files, "nextPageToken" => next_page_token}}
     }}
  end
end
