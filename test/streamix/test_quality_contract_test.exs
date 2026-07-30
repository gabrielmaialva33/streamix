defmodule Streamix.TestQualityContractTest do
  use ExUnit.Case, async: true

  test "tests synchronize on observable events instead of fixed sleeps" do
    forbidden_calls = [
      {"Process." <> "sleep(", "Process.sleep/1"},
      {"wait_for_" <> "timeout(", "browser wait_for_timeout"}
    ]

    test_files =
      Path.wildcard("test/**/*.ex") ++
        Path.wildcard("test/**/*.exs")

    offenders =
      for path <- test_files,
          source = File.read!(path),
          {needle, label} <- forbidden_calls,
          String.contains?(source, needle),
          do: {path, label}

    assert offenders == []
  end
end
