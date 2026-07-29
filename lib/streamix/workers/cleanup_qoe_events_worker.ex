defmodule Streamix.Workers.CleanupQoeEventsWorker do
  @moduledoc """
  Enforces the bounded retention window for client QoE samples.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 3,
    unique: [period: :timer.hours(23), fields: [:worker]]

  alias Streamix.Qoe

  require Logger

  @default_retention_days 90

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    retention_days = retention_days(args)
    cutoff = DateTime.add(DateTime.utc_now(), -retention_days * 86_400, :second)
    {deleted, nil} = Qoe.purge_before(cutoff)

    Logger.info("[QoE Cleanup] removed=#{deleted} retention_days=#{retention_days}")
    :ok
  end

  defp retention_days(%{"retention_days" => days})
       when is_integer(days) and days >= 7 and days <= 365,
       do: days

  defp retention_days(_args), do: @default_retention_days
end
