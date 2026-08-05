defmodule Streamix.Queue.ConnectionTest do
  use ExUnit.Case, async: false

  alias Streamix.Queue.Connection

  setup do
    previous = Application.get_env(:streamix, :rabbitmq)

    Application.put_env(:streamix, :rabbitmq,
      connection: [
        host: "mq.example",
        port: 5673,
        username: "user+name",
        password: "p@ss:/ word",
        virtual_host: "/stream ix"
      ]
    )

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:streamix, :rabbitmq)
      else
        Application.put_env(:streamix, :rabbitmq, previous)
      end
    end)

    :ok
  end

  test "percent-encodes credentials and the virtual host in the Broadway URL" do
    assert Connection.connection_url() ==
             "amqp://user%2Bname:p%40ss%3A%2F+word@mq.example:5673/%2Fstream+ix"
  end
end
