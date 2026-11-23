defmodule StreamixWeb.PlaywrightCase do
  @moduledoc """
  Case template for browser tests: a Fluffy Playwright session as `conn`, in
  the test's SQL sandbox.
  """

  use ExUnit.CaseTemplate
  use Playwright.Test

  using opts do
    quote do
      use Playwright.Test, unquote(opts)
      import Fluffy.PhoenixTest
    end
  end

  setup tags do
    Streamix.DataCase.setup_sandbox(tags)
    %{conn: Fluffy.PhoenixTest.start_session(:playwright)}
  end
end
