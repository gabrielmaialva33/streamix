defmodule Streamix.DeployContractTest do
  use ExUnit.Case, async: true

  @script Path.expand("../../scripts/deploy-production.sh", __DIR__)

  # A deploy recreates only the app container. `docker compose up` or `run`
  # without --no-deps also starts the services streamix depends on and
  # recreates any whose image changed; on 2026-11-10 a Dependabot image bump
  # restarted the Postgres and Redis that other apps share, mid-deploy.
  test "every compose up and run in the deploy leaves dependencies alone" do
    commands =
      @script
      |> File.read!()
      |> String.split("\n")
      |> Enum.filter(fn line ->
        Regex.match?(~r/compose\b.*\b(up|run)\b/, line) and
          not String.starts_with?(String.trim(line), "#")
      end)

    assert commands != []

    for command <- commands do
      assert command =~ "--no-deps", "missing --no-deps: #{String.trim(command)}"
    end
  end
end
