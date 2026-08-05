defmodule Streamix.QueueTest do
  use ExUnit.Case, async: false

  alias Streamix.Queue

  setup do
    previous = Application.get_env(:streamix, :rabbitmq)
    Application.put_env(:streamix, :rabbitmq, enabled: false)

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:streamix, :rabbitmq)
      else
        Application.put_env(:streamix, :rabbitmq, previous)
      end
    end)

    :ok
  end

  test "generic tasks fail explicitly when RabbitMQ is disabled" do
    refute Queue.enabled?()

    assert {:error, :rabbitmq_disabled} =
             Queue.enqueue(:iptv_movies, %{provider_id: 7})

    assert {:error, :rabbitmq_disabled} =
             Queue.enqueue_sync(%{type: :gindex_movies, provider_id: 7, path: "/movies/"})
  end
end
