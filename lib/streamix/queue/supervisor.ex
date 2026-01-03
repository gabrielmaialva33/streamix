defmodule Streamix.Queue.Supervisor do
  @moduledoc """
  Supervisor for the Queue system (RabbitMQ + Broadway).

  Starts the connection manager and Broadway pipelines for each priority queue.
  """

  use Supervisor

  require Logger

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    Logger.info("[Queue] Starting Queue supervisor with RabbitMQ + Broadway")

    children = [
      # Connection manager
      Streamix.Queue.Connection,

      # Broadway pipelines for each priority queue (unique IDs required)
      Supervisor.child_spec(
        {Streamix.Queue.SyncPipeline, queue: "streamix.sync.high"},
        id: :sync_pipeline_high
      ),
      Supervisor.child_spec(
        {Streamix.Queue.SyncPipeline, queue: "streamix.sync.normal"},
        id: :sync_pipeline_normal
      ),
      Supervisor.child_spec(
        {Streamix.Queue.SyncPipeline, queue: "streamix.sync.low"},
        id: :sync_pipeline_low
      )
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc """
  Returns child specs for the queue system if enabled.

  This is used by the main Application supervisor to conditionally
  start the queue system.
  """
  def child_spec_if_enabled do
    config = Application.get_env(:streamix, :rabbitmq, [])

    if Keyword.get(config, :enabled, false) do
      [__MODULE__]
    else
      Logger.info("[Queue] RabbitMQ disabled, queue system not started")
      []
    end
  end
end
