defmodule Streamix.AI.QdrantTest do
  use ExUnit.Case, async: true

  alias Streamix.AI.Qdrant

  test "disabled client fails fast without requiring a Qdrant service" do
    assert Qdrant.enabled?() == false
    assert Qdrant.health_check() == {:error, :disabled}
    assert Qdrant.get_point("movies", 123) == {:error, :disabled}
  end
end
