defmodule StreamixWeb.StreamControllerTest do
  use ExUnit.Case, async: true

  test "preserves upstream client error statuses" do
    assert StreamixWeb.StreamController.normalize_upstream_status(403) == 403
    assert StreamixWeb.StreamController.normalize_upstream_status(404) == 404
  end
end
