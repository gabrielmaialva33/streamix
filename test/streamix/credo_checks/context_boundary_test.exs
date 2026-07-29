Code.require_file(Path.expand("../../../credo_checks/context_boundary.ex", __DIR__))

defmodule Streamix.CredoChecks.ContextBoundaryTest do
  use Credo.Test.Case

  alias Streamix.CredoChecks.ContextBoundary

  setup_all do
    case Application.ensure_all_started(:credo) do
      {:ok, _apps} -> :ok
      {:error, {:credo, {{:already_started, _pid}, _start_spec}}} -> :ok
    end
  end

  test "accepts calls through a public context facade" do
    """
    defmodule StreamixWeb.Example do
      alias Streamix.Iptv

      def load(id), do: Iptv.get_movie(id)
    end
    """
    |> to_source_file("lib/streamix_web/example.ex")
    |> run_check(ContextBoundary)
    |> refute_issues()
  end

  test "rejects a nested context alias" do
    """
    defmodule StreamixWeb.Example do
      alias Streamix.Iptv.Movie
    end
    """
    |> to_source_file("lib/streamix_web/example.ex")
    |> run_check(ContextBoundary)
    |> assert_issue(fn issue ->
      assert issue.trigger == "Streamix.Iptv.Movie"
      assert issue.line_no == 2
    end)
  end

  test "rejects grouped nested context aliases" do
    """
    defmodule StreamixWeb.Example do
      alias Streamix.Iptv.{Movie, Series}
    end
    """
    |> to_source_file("lib/streamix_web/example.ex")
    |> run_check(ContextBoundary)
    |> assert_issue(fn issue ->
      assert issue.trigger == "Streamix.Iptv.{...}"
    end)
  end

  test "ignores context internals outside the web delivery layer" do
    """
    defmodule Streamix.Workers.Example do
      alias Streamix.Iptv.Movie
    end
    """
    |> to_source_file("lib/streamix/workers/example.ex")
    |> run_check(ContextBoundary)
    |> refute_issues()
  end
end
