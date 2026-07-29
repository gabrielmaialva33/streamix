defmodule Streamix.RepoTest do
  use ExUnit.Case, async: true

  test "test pool scales with ExUnit concurrency unless explicitly overridden" do
    pool_size =
      :streamix
      |> Application.fetch_env!(Streamix.Repo)
      |> Keyword.fetch!(:pool_size)

    expected =
      case System.get_env("TEST_POOL_SIZE") do
        nil -> System.schedulers_online() * 2
        configured -> String.to_integer(configured)
      end

    assert pool_size == expected
    assert pool_size >= ExUnit.configuration()[:max_cases] * 2
  end
end
