defmodule StreamixWeb.PlaywrightSupport do
  @moduledoc """
  Repo-specific lifecycle helpers for browser tests.

  `PhoenixTest.Playwright.Case` closes each browser context asynchronously.
  Streamix LiveViews keep querying through the SQL sandbox until their socket
  closes, so the context must be gone before the sandbox owner is released.
  """

  alias PhoenixTest.Playwright
  alias PlaywrightEx.BrowserContext

  @doc false
  def register_context_cleanup(%{conn: session}) do
    Playwright.unwrap(session, fn %{context_id: context_id} ->
      ExUnit.Callbacks.on_exit({__MODULE__, context_id}, fn ->
        {:ok, _response} = BrowserContext.close(context_id, timeout: 5_000)
      end)
    end)

    :ok
  end
end
