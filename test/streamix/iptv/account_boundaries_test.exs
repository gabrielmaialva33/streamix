defmodule Streamix.Iptv.AccountBoundariesTest do
  use ExUnit.Case, async: true

  alias Streamix.Iptv.{Favorite, Provider, WatchEvent, WatchProgress}

  test "account ownership stays a scalar foreign key inside IPTV schemas" do
    for schema <- [Favorite, Provider, WatchEvent, WatchProgress] do
      assert schema.__schema__(:type, :user_id) == :id
      refute :user in schema.__schema__(:associations)
    end
  end
end
