defmodule Streamix.Queue.Connection do
  @moduledoc """
  Manages the AMQP connection to RabbitMQ.

  This module provides a supervised connection that automatically
  reconnects on failure.
  """

  use GenServer

  require Logger

  @reconnect_interval 5_000

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Returns the current AMQP connection if available.
  """
  def get_connection do
    GenServer.call(__MODULE__, :get_connection)
  end

  @doc """
  Returns the current AMQP channel if available.
  """
  def get_channel do
    GenServer.call(__MODULE__, :get_channel)
  end

  @doc """
  Returns the connection URL for Broadway.
  """
  def connection_url do
    config = Application.get_env(:streamix, :rabbitmq, [])
    conn = Keyword.get(config, :connection, [])

    host = Keyword.get(conn, :host, "localhost")
    port = Keyword.get(conn, :port, 5672)
    username = Keyword.get(conn, :username, "guest")
    password = Keyword.get(conn, :password, "guest")
    vhost = Keyword.get(conn, :virtual_host, "/") |> URI.encode_www_form()

    "amqp://#{username}:#{password}@#{host}:#{port}/#{vhost}"
  end

  # GenServer callbacks

  @impl true
  def init(_opts) do
    send(self(), :connect)
    {:ok, %{connection: nil, channel: nil}}
  end

  @impl true
  def handle_call(:get_connection, _from, %{connection: conn} = state) do
    {:reply, conn, state}
  end

  @impl true
  def handle_call(:get_channel, _from, %{channel: channel} = state) do
    {:reply, channel, state}
  end

  @impl true
  def handle_info(:connect, state) do
    config = Application.get_env(:streamix, :rabbitmq, [])
    conn_opts = Keyword.get(config, :connection, [])

    case AMQP.Connection.open(conn_opts) do
      {:ok, connection} ->
        Process.monitor(connection.pid)

        case AMQP.Channel.open(connection) do
          {:ok, channel} ->
            Logger.info("[RabbitMQ] Connected successfully")
            setup_queues(channel)
            {:noreply, %{connection: connection, channel: channel}}

          {:error, reason} ->
            Logger.error("[RabbitMQ] Failed to open channel: #{inspect(reason)}")
            schedule_reconnect()
            {:noreply, state}
        end

      {:error, reason} ->
        Logger.error("[RabbitMQ] Connection failed: #{inspect(reason)}")
        schedule_reconnect()
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, _pid, reason}, state) do
    Logger.warning("[RabbitMQ] Connection lost: #{inspect(reason)}")
    schedule_reconnect()
    {:noreply, %{state | connection: nil, channel: nil}}
  end

  # Private functions

  defp setup_queues(channel) do
    # Declare exchanges
    :ok = AMQP.Exchange.declare(channel, "streamix.sync", :topic, durable: true)
    :ok = AMQP.Exchange.declare(channel, "streamix.sync.dlx", :topic, durable: true)

    # Declare queues with priorities and dead-letter exchange
    # High priority queue for important syncs
    {:ok, _} =
      AMQP.Queue.declare(channel, "streamix.sync.high",
        durable: true,
        arguments: [
          {"x-dead-letter-exchange", :longstr, "streamix.sync.dlx"},
          {"x-dead-letter-routing-key", :longstr, "sync.dead"},
          {"x-max-priority", :byte, 10}
        ]
      )

    # Normal priority queue
    {:ok, _} =
      AMQP.Queue.declare(channel, "streamix.sync.normal",
        durable: true,
        arguments: [
          {"x-dead-letter-exchange", :longstr, "streamix.sync.dlx"},
          {"x-dead-letter-routing-key", :longstr, "sync.dead"},
          {"x-max-priority", :byte, 10}
        ]
      )

    # Low priority queue for batch operations
    {:ok, _} =
      AMQP.Queue.declare(channel, "streamix.sync.low",
        durable: true,
        arguments: [
          {"x-dead-letter-exchange", :longstr, "streamix.sync.dlx"},
          {"x-dead-letter-routing-key", :longstr, "sync.dead"},
          {"x-max-priority", :byte, 10}
        ]
      )

    # Dead letter queue for failed messages
    {:ok, _} = AMQP.Queue.declare(channel, "streamix.sync.dead", durable: true)

    # Bind queues to exchanges
    :ok = AMQP.Queue.bind(channel, "streamix.sync.high", "streamix.sync", routing_key: "sync.high.*")
    :ok = AMQP.Queue.bind(channel, "streamix.sync.normal", "streamix.sync", routing_key: "sync.normal.*")
    :ok = AMQP.Queue.bind(channel, "streamix.sync.low", "streamix.sync", routing_key: "sync.low.*")
    :ok = AMQP.Queue.bind(channel, "streamix.sync.dead", "streamix.sync.dlx", routing_key: "sync.dead")

    Logger.info("[RabbitMQ] Queues and exchanges configured")
  end

  defp schedule_reconnect do
    Process.send_after(self(), :connect, @reconnect_interval)
  end
end
