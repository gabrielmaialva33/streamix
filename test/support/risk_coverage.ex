defmodule Streamix.TestSupport.RiskCoverage do
  @moduledoc false

  alias Mix.Tasks.Test.Coverage

  @floors [
    {StreamixWeb.StreamToken, 95.0},
    {StreamixWeb.StreamToken.Resolver, 60.0},
    {Streamix.Crypto, 90.0},
    {Streamix.Iptv.EncryptedField, 45.0},
    {Streamix.Billing, 75.0},
    {Streamix.Access, 70.0},
    {Streamix.Qoe, 85.0},
    {Streamix.Torrent.Catalog, 70.0},
    {Streamix.Torrent.StatsRefresher, 70.0}
  ]

  def start(compile_path, opts) do
    generate_report = Coverage.start(compile_path, opts)

    if opts[:export] do
      generate_report
    else
      fn ->
        generate_report.()
        enforce_floors!()
      end
    end
  end

  def floors, do: @floors

  def percentage_for(results, module) do
    line_coverage =
      Enum.reduce(results, %{}, fn
        {{^module, line}, {1, 0}}, acc when line != 0 ->
          Map.put(acc, line, true)

        {{^module, line}, {0, 1}}, acc when line != 0 ->
          Map.put_new(acc, line, false)

        _result, acc ->
          acc
      end)

    case Map.values(line_coverage) do
      [] ->
        :missing

      lines ->
        covered = Enum.count(lines, & &1)
        covered / length(lines) * 100
    end
  end

  defp enforce_floors! do
    {:result, results, _failures} = :cover.analyse(:coverage, :line)

    measured =
      Enum.map(@floors, fn {module, floor} ->
        {module, percentage_for(results, module), floor}
      end)

    Mix.shell().info("\nRisk-focused coverage floors:\n")

    Enum.each(measured, fn {module, percentage, floor} ->
      Mix.shell().info(
        "  #{inspect(module)}: #{format_percentage(percentage)} (minimum #{format_percentage(floor)})"
      )
    end)

    failures =
      Enum.reject(measured, fn
        {_module, :missing, _floor} -> false
        {_module, percentage, floor} -> percentage >= floor
      end)

    if failures != [] do
      details =
        Enum.map_join(failures, ", ", fn {module, percentage, floor} ->
          "#{inspect(module)}=#{format_percentage(percentage)}<#{format_percentage(floor)}"
        end)

      Mix.raise("risk-focused coverage floor failed: #{details}")
    end
  end

  defp format_percentage(:missing), do: "missing"
  defp format_percentage(value), do: "#{Float.round(value, 2)}%"
end
