defmodule Streamix.SyncWorker do
  @moduledoc """
  `use Streamix.SyncWorker, queue: :sync, max_attempts: 3` wraps the common
  shape every long-running sync worker in this app needed by hand: an
  `Oban.Worker`, `require Logger`, a module-name-prefixed log helper, and
  a `broadcast_status/3` that goes to `Streamix.PubSub`.

  ## Usage

      defmodule Streamix.Workers.SyncFoo do
        use Streamix.SyncWorker, queue: :sync, max_attempts: 3,
          unique: [period: 300, keys: [:provider_id]]

        @impl Oban.Worker
        def perform(%Oban.Job{args: args}) do
          log_info("starting foo sync")
          broadcast_status("provider:\#{args["provider_id"]}", :syncing)
          # ...
        end
      end

  Every option except `:pubsub` is forwarded verbatim to `use Oban.Worker`.
  Workers that need a custom prefix can still define their own
  `log_info/1` since these are `defp`.
  """

  defmacro __using__(opts) do
    {_pubsub, oban_opts} = Keyword.pop(opts, :pubsub, Streamix.PubSub)

    quote do
      use Oban.Worker, unquote(oban_opts)
      require Logger

      defp log_info(msg),
        do: Logger.info("[#{Streamix.SyncWorker.short_name(__MODULE__)}] #{msg}")

      defp log_warning(msg),
        do: Logger.warning("[#{Streamix.SyncWorker.short_name(__MODULE__)}] #{msg}")

      defp log_error(msg),
        do: Logger.error("[#{Streamix.SyncWorker.short_name(__MODULE__)}] #{msg}")

      defp broadcast_status(topic, status, metadata \\ %{}) when is_binary(topic) do
        payload = Map.merge(%{status: status}, metadata)
        Phoenix.PubSub.broadcast(Streamix.PubSub, topic, {status, payload})
      end
    end
  end

  @doc false
  def short_name(module) do
    module
    |> Module.split()
    |> List.last()
  end
end
