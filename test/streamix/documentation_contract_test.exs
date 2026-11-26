defmodule Streamix.DocumentationContractTest do
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)
  @entrypoints ~w(AGENTS.md CONTRIBUTING.md README.md README.pt.md)

  test "onboarding documents link to existing local references" do
    broken =
      Enum.flat_map(@entrypoints, fn document ->
        path = Path.join(@root, document)

        ~r/\[[^\]]*\]\(([^\s)]+)\)/
        |> Regex.scan(File.read!(path), capture: :all_but_first)
        |> Enum.flat_map(fn [target] ->
          uri = URI.parse(target)

          if is_nil(uri.scheme) and is_nil(uri.host) and uri.path not in [nil, ""] do
            resolved = Path.expand(URI.decode(uri.path), Path.dirname(path))
            if File.exists?(resolved), do: [], else: ["#{document} -> #{target}"]
          else
            []
          end
        end)
      end)

    assert broken == [], "Broken local documentation links:\n#{Enum.join(broken, "\n")}"
  end
end
