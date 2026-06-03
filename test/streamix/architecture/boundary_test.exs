defmodule Streamix.Architecture.BoundaryTest do
  use ExUnit.Case, async: true

  @moduledoc false

  @core_path "lib/streamix/**/*.ex"
  @web_path "lib/streamix_web/**/*.ex"

  @allowed_web_boundary_references %{
    "lib/streamix/application.ex" => [
      "StreamixWeb.Telemetry",
      "StreamixWeb.Presence",
      "StreamixWeb.Endpoint"
    ]
  }

  @forbidden_web_internal_module_references [
    {"Streamix.Iptv.Sync.Series.*", ~r/\bStreamix\.Iptv\.Sync\.Series\.(?:[A-Z]|\{)/},
    {"Streamix.Iptv.Sync.Normalizers.*", ~r/\bStreamix\.Iptv\.Sync\.Normalizers\.(?:[A-Z]|\{)/},
    {"Streamix.Iptv.TmdbClient.*", ~r/\bStreamix\.Iptv\.TmdbClient\.(?:[A-Z]|\{)/},
    {"Streamix.Gindex.Sync.*", ~r/\bStreamix\.Iptv\.Gindex\.Sync\.(?:[A-Z]|\{)/},
    {"Streamix.AI.UserAnalytics.*", ~r/\bStreamix\.AI\.UserAnalytics\.(?:[A-Z]|\{)/}
  ]

  test "core Streamix modules do not depend on StreamixWeb" do
    violations =
      @core_path
      |> Path.wildcard()
      |> Enum.sort()
      |> Enum.flat_map(&streamix_web_references/1)
      |> Enum.reject(&allowed_web_boundary_reference?/1)

    assert violations == [],
           """
           Core modules under lib/streamix must not depend on StreamixWeb.

           Move web concerns to lib/streamix_web or add a narrowly justified
           infrastructure allowlist entry when the dependency is part of OTP
           application wiring.

           Violations:
           #{format_violations(violations)}
           """
  end

  test "web modules depend on public facades instead of internal implementation modules" do
    violations =
      @web_path
      |> Path.wildcard()
      |> Enum.sort()
      |> Enum.flat_map(&web_internal_module_references/1)

    assert violations == [],
           """
           Modules under lib/streamix_web must depend on public context facades,
           not internal implementation modules.

           Allowed facades include:
           - Streamix.Iptv.Sync.Series
           - Streamix.Iptv.TmdbClient
           - Streamix.Gindex.Sync
           - Streamix.AI.UserAnalytics

           Violations:
           #{format_violations(violations)}
           """
  end

  defp streamix_web_references(path) do
    path
    |> File.read!()
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.filter(fn {line, _line_number} -> String.contains?(line, "StreamixWeb") end)
    |> Enum.map(fn {line, line_number} ->
      %{path: path, line_number: line_number, line: String.trim(line)}
    end)
  end

  defp web_internal_module_references(path) do
    path
    |> File.read!()
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {line, line_number} ->
      @forbidden_web_internal_module_references
      |> Enum.filter(fn {_namespace, pattern} -> Regex.match?(pattern, line) end)
      |> Enum.map(fn {namespace, _pattern} ->
        %{path: path, line_number: line_number, line: String.trim(line), namespace: namespace}
      end)
    end)
  end

  defp allowed_web_boundary_reference?(%{path: path, line: line}) do
    path
    |> allowed_reference_patterns()
    |> Enum.any?(&String.contains?(line, &1))
  end

  defp allowed_reference_patterns(path) do
    Map.get(@allowed_web_boundary_references, path, [])
  end

  defp format_violations([]), do: "none"

  defp format_violations(violations) do
    Enum.map_join(violations, "\n", fn violation ->
      namespace = Map.get(violation, :namespace)

      [
        "#{violation.path}:#{violation.line_number}:",
        namespace && "[#{namespace}]",
        violation.line
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" ")
    end)
  end
end
