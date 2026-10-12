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

  test "a live window drops references no refresh has named for longer than it" do
    registry = Registry.new("https://93.184.216.34/live.m3u8", :playlist, window_seconds: 60)
    root = Registry.root(registry)
    segment = fn n -> {"https://93.184.216.34/seg-#{n}.ts", :media} end

    # Refresh at t=0 names 1..5; at t=30 the playlist has moved to 3..7.
    assert {:ok, first_ids, registry} = Registry.register(registry, Enum.map(1..5, segment), 0)
    assert {:ok, second_ids, registry} = Registry.register(registry, Enum.map(3..7, segment), 30)

    # Still-listed segments keep their identifiers across refreshes.
    assert Enum.slice(first_ids, 2..4) == Enum.slice(second_ids, 0..2)
    assert Registry.size(registry) == 8

    # At t=61, 1 and 2 were last named at t=0 and go; 3..7 (named at 30) stay.
    assert {:ok, _ids, registry} = Registry.register(registry, Enum.map(5..9, segment), 61)
    assert Registry.lookup(registry, Enum.at(first_ids, 0)) == :error
    assert Registry.lookup(registry, Enum.at(first_ids, 1)) == :error
    assert {:ok, _} = Registry.lookup(registry, Enum.at(first_ids, 2))
    assert {:ok, %{kind: :playlist}} = Registry.lookup(registry, root)
    assert Registry.size(registry) == 1 + 7

    # A channel left running for days stays at its window, never at the caps.
    registry =
      Enum.reduce(1..5_000, registry, fn tick, acc ->
        refs = Enum.map((tick * 3)..(tick * 3 + 4), segment)
        {:ok, _ids, acc} = Registry.register(acc, refs, 100 + tick * 10)
        acc
      end)

    assert Registry.size(registry) < 40
    assert {:ok, %{kind: :playlist}} = Registry.lookup(registry, root)
  end

  test "growth is bounded by resource count and URL bytes" do
    registry = Registry.new("https://93.184.216.34/master.m3u8", :playlist)

    too_many = for n <- 1..20_000, do: {"https://93.184.216.34/#{n}.ts", :media}
    assert {:error, :resource_limit} = Registry.register(registry, too_many)

    long = "https://93.184.216.34/" <> String.duplicate("a", 5 * 1024 * 1024)
    assert {:error, :resource_limit} = Registry.register(registry, [{long, :media}])
  end
end
