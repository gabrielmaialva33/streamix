defmodule Streamix.Hls.RegistryTest do
  use ExUnit.Case, async: true

  alias Streamix.Hls.Registry

  test "a reference keeps its identifier and only registered identifiers resolve" do
    registry = Registry.new("https://93.184.216.34/master.m3u8", :playlist)
    root = Registry.root(registry)

    assert root =~ ~r/^[A-Za-z0-9_-]{24}\.m3u8$/
    assert Registry.root_url(registry) == "https://93.184.216.34/master.m3u8"

    refs = [{"https://93.184.216.34/v.m3u8", :playlist}, {"https://93.184.216.34/s.ts", :media}]
    assert {:ok, [variant, segment], registry} = Registry.register(registry, refs)
    assert variant =~ ~r/\.m3u8$/
    assert segment =~ ~r/\.bin$/

    assert {:ok, [^segment, ^variant], _registry} =
             Registry.register(registry, Enum.reverse(refs))

    assert {:ok, %{url: "https://93.184.216.34/s.ts", kind: :media}} =
             Registry.lookup(registry, segment)

    assert Registry.lookup(registry, "unknown.bin") == :error
  end

  test "a custom suffix names media by kind and URL" do
    suffix = fn
      :playlist, _url -> ".m3u8"
      _kind, url -> if String.ends_with?(url, ".ts"), do: ".ts", else: ".bin"
    end

    registry = Registry.new("https://93.184.216.34/master.m3u8", :playlist, suffix: suffix)

    assert {:ok, [ts, other], _registry} =
             Registry.register(registry, [
               {"https://93.184.216.34/a.ts", :media},
               {"https://93.184.216.34/b.js", :media}
             ])

    assert ts =~ ~r/\.ts$/
    assert other =~ ~r/\.bin$/
  end

  test "growth is bounded by resource count and URL bytes" do
    registry = Registry.new("https://93.184.216.34/master.m3u8", :playlist)

    too_many = for n <- 1..20_000, do: {"https://93.184.216.34/#{n}.ts", :media}
    assert {:error, :resource_limit} = Registry.register(registry, too_many)

    long = "https://93.184.216.34/" <> String.duplicate("a", 5 * 1024 * 1024)
    assert {:error, :resource_limit} = Registry.register(registry, [{long, :media}])
  end
end
