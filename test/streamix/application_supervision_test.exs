defmodule Streamix.ApplicationSupervisionTest do
  use ExUnit.Case, async: true

  alias Streamix.Application, as: StreamixApplication

  test "runtime bootstrap is supervised and the HTTP endpoint starts last" do
    child_ids =
      StreamixApplication.children()
      |> Enum.map(&Supervisor.child_spec(&1, []).id)

    assert Streamix.RuntimeBootstrap in child_ids

    assert Enum.find_index(child_ids, &(&1 == Oban)) <
             Enum.find_index(child_ids, &(&1 == StreamixWeb.Endpoint))

    assert List.last(child_ids) == StreamixWeb.Endpoint
  end

  test "provider bootstrap is a one-shot supervised task" do
    assert %{id: Streamix.ProviderBootstrap, restart: :temporary, type: :worker} =
             Supervisor.child_spec({Streamix.ProviderBootstrap, []}, [])
  end
end
