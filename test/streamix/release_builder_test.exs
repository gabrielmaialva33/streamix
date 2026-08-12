defmodule Streamix.ReleaseBuilderTest do
  use ExUnit.Case, async: true

  alias Streamix.ReleaseBuilder

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "streamix-release-builder-#{System.unique_integer([:positive, :monotonic])}"
      )

    ebin = Path.join(root, "ebin")
    File.mkdir_p!(ebin)
    on_exit(fn -> File.rm_rf!(root) end)

    %{app_path: Path.join(ebin, "color.app"), root: root}
  end

  test "normalizes Unicode metadata that Mix cannot copy as iodata", context do
    description = ~c"Color difference ΔE2000"
    write_app_spec(context.app_path, description)

    release = release_with_color(context.root)

    assert ReleaseBuilder.prepare(release) == release

    assert {:ok, [{:application, :color, properties}]} = :file.consult(context.app_path)
    assert Keyword.fetch!(properties, :description) == ~c"Color difference DeltaE2000"
  end

  test "does not rewrite an already compatible application spec", context do
    write_app_spec(context.app_path, ~c"Color library")
    original = File.read!(context.app_path)
    release = release_with_color(context.root)

    assert ReleaseBuilder.prepare(release) == release
    assert File.read!(context.app_path) == original
  end

  test "is a no-op when color is no longer part of the release" do
    release = %Mix.Release{applications: %{}}

    assert ReleaseBuilder.prepare(release) == release
  end

  defp release_with_color(root) do
    %Mix.Release{applications: %{color: [path: root]}}
  end

  defp write_app_spec(path, description) do
    application = {:application, :color, description: description, vsn: ~c"0.13.0"}

    contents =
      :io_lib.format("%% coding: utf-8~n~tp.~n", [application])
      |> IO.chardata_to_string()

    File.write!(path, contents)
  end
end
