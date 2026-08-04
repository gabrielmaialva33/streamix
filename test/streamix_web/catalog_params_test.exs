defmodule StreamixWeb.Catalog.ParamsTest do
  use ExUnit.Case, async: true

  alias StreamixWeb.Catalog.Params

  test "clamps pagination to safe positive ranges" do
    assert Params.movies_opts(%{"limit" => "-10", "offset" => "-20"})
           |> Keyword.take([:limit, :offset]) == [limit: 1, offset: 0]

    assert Params.movies_opts(%{"limit" => "999", "offset" => "999999"})
           |> Keyword.take([:limit, :offset]) == [limit: 100, offset: 100_000]
  end

  test "rejects partial integers and non-positive category ids" do
    assert Params.movies_opts(%{"limit" => "12junk", "category_id" => "9x"})
           |> Keyword.take([:limit, :category_id]) == [limit: 20, category_id: nil]

    assert Params.movies_opts(%{"category_id" => "0"})[:category_id] == nil
    assert Params.movies_opts(%{"category_id" => "42"})[:category_id] == 42
  end
end
