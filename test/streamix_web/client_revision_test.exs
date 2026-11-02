defmodule StreamixWeb.ClientRevisionTest do
  use StreamixWeb.ConnCase, async: false

  test "the rendered page exposes only a validated build SHA", %{conn: conn} do
    previous = System.get_env("STREAMIX_REVISION")

    on_exit(fn ->
      if previous,
        do: System.put_env("STREAMIX_REVISION", previous),
        else: System.delete_env("STREAMIX_REVISION")
    end)

    revision = String.duplicate("b", 40)
    System.put_env("STREAMIX_REVISION", revision)
    html = conn |> get(~p"/") |> html_response(200) |> LazyHTML.from_document()

    assert html
           |> LazyHTML.query("meta[name=streamix-client-revision]")
           |> LazyHTML.attribute("content") == [revision]
  end
end
