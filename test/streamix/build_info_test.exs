defmodule Streamix.BuildInfoTest do
  use ExUnit.Case, async: false

  alias Streamix.BuildInfo

  @version Path.expand("../../VERSION", __DIR__) |> File.read!() |> String.trim()

  setup do
    previous_revision = System.get_env("STREAMIX_REVISION")

    on_exit(fn ->
      if previous_revision do
        System.put_env("STREAMIX_REVISION", previous_revision)
      else
        System.delete_env("STREAMIX_REVISION")
      end
    end)
  end

  test "reports the baked revision without exposing unrelated environment values" do
    System.put_env("STREAMIX_REVISION", "abc123")

    assert %{
             version: @version,
             revision: "abc123",
             asset_version: asset_version
           } = BuildInfo.snapshot()

    assert is_binary(asset_version)
  end

  test "falls back to an explicit unknown revision" do
    System.delete_env("STREAMIX_REVISION")

    assert BuildInfo.revision() == "unknown"
  end
end
