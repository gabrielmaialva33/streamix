defmodule StreamixWeb.Helpers.ImageCache do
  @moduledoc "Bounded resize admission and atomic, budgeted disk cache publication."
  use GenServer
  require Logger

  @timeout 60_000
  @max_waiters 32

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  def fetch(key, producer, opts, server \\ __MODULE__) do
    GenServer.call(server, {:fetch, key, producer, opts}, @timeout + 5_000)
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    {:ok,
     %{
       jobs: %{},
       queue: [],
       max_running: Keyword.get(opts, :max_running, 2),
       max_queued: Keyword.get(opts, :max_queued, 32)
     }}
  end

  @impl true
  def handle_call({:fetch, key, producer, opts}, from, state) do
    path = cache_path(key, opts)

    case cached(path, opts) do
      {:ok, bytes} -> {:reply, {:ok, bytes, :cache}, state}
      :miss -> admit(path, producer, opts, from, state)
    end
  end

  defp admit(path, producer, opts, from, state) do
    existing = Enum.find(state.jobs, fn {_ref, job} -> job.path == path end)

    cond do
      existing ->
        join_existing(existing, from, state)

      running(state) < state.max_running ->
        {:noreply, start_job(new_job(path, producer, opts, from), state)}

      length(state.queue) < state.max_queued ->
        ref = make_ref()
        job = new_job(path, producer, opts, from)
        timer = Process.send_after(self(), {:expire, ref}, @timeout)

        state = %{
          state
          | jobs: Map.put(state.jobs, ref, %{job | timer: timer}),
            queue: state.queue ++ [ref]
        }

        :telemetry.execute([:streamix, :image_cache, :queued], %{count: length(state.queue)}, %{})
        {:noreply, state}

      true ->
        {:reply, {:error, :cache_busy}, state}
    end
  end

  defp join_existing({ref, job}, from, state) do
    if length(job.waiters) < @max_waiters,
      do: {:noreply, put_in(state.jobs[ref].waiters, [from | job.waiters])},
      else: {:reply, {:error, :cache_busy}, state}
  end

  defp new_job(path, producer, opts, from),
    do: %{
      path: path,
      producer: producer,
      opts: opts,
      waiters: [from],
      caller: elem(from, 0),
      task: nil,
      timer: nil,
      deadline: System.monotonic_time(:millisecond) + @timeout
    }

  defp running(state), do: Enum.count(state.jobs, fn {_ref, job} -> not is_nil(job.task) end)

  defp start_job(job, state) do
    manager = self()

    task =
      Task.Supervisor.async_nolink(Streamix.TaskSupervisor, fn ->
        # A killed manager must not leave workers alive alongside its replacement.
        Process.link(manager)
        Process.put(:"$callers", [job.caller])
        job.producer.()
      end)

    remaining = max(job.deadline - System.monotonic_time(:millisecond), 0)
    timer = Process.send_after(self(), {:expire, task.ref}, remaining)
    put_in(state.jobs[task.ref], %{job | task: task, timer: timer})
  end

  defp start_next(%{queue: []} = state), do: state

  defp start_next(%{queue: [ref | rest]} = state) do
    if running(state) < state.max_running do
      {job, jobs} = Map.pop(state.jobs, ref)
      Process.cancel_timer(job.timer)
      start_job(job, %{state | jobs: jobs, queue: rest}) |> start_next()
    else
      state
    end
  end

  @impl true
  def handle_info({ref, result}, state) when is_reference(ref) do
    case Map.pop(state.jobs, ref) do
      {nil, _jobs} ->
        {:noreply, state}

      {job, jobs} ->
        Process.demonitor(ref, [:flush])
        Process.cancel_timer(job.timer)
        reply = publish_result(job, result)
        Enum.each(job.waiters, &GenServer.reply(&1, reply))
        {:noreply, start_next(%{state | jobs: jobs})}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state), do: fail_job(ref, state)
  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  def handle_info({:expire, ref}, state) do
    case state.jobs[ref] do
      %{task: %Task{} = task} -> Task.shutdown(task, :brutal_kill)
      _ -> :ok
    end

    fail_job(ref, state)
  end

  @impl true
  def terminate(_reason, state) do
    Enum.each(state.jobs, fn
      {_ref, %{task: %Task{} = task}} -> Task.shutdown(task, :brutal_kill)
      _ -> :ok
    end)
  end

  defp fail_job(ref, state) do
    case Map.pop(state.jobs, ref) do
      {nil, _jobs} ->
        {:noreply, state}

      {job, jobs} ->
        Process.cancel_timer(job.timer)
        Enum.each(job.waiters, &GenServer.reply(&1, {:error, :resize_failed}))
        {:noreply, start_next(%{state | jobs: jobs, queue: List.delete(state.queue, ref)})}
    end
  end

  defp publish_result(job, {:ok, bytes}) when is_binary(bytes) do
    publish(job.path, bytes, job.opts)
    {:ok, bytes, :origin}
  end

  defp publish_result(_job, {:error, _reason} = error), do: error
  defp publish_result(_job, _result), do: {:error, :resize_failed}

  defp cached(path, opts) do
    with {:ok, stat} <- File.stat(path, time: :posix),
         true <- fresh?(stat, opts),
         true <- stat.size <= Keyword.get(opts, :max_bytes, 512 * 1024 * 1024),
         {:ok, bytes} <- File.read(path) do
      {:ok, bytes}
    else
      _ -> :miss
    end
  end

  defp fresh?(stat, opts),
    do: System.system_time(:second) - stat.mtime < Keyword.get(opts, :ttl_seconds, 30 * 86_400)

  defp publish(path, bytes, opts) do
    max_bytes = Keyword.get(opts, :max_bytes, 512 * 1024 * 1024)
    max_entries = Keyword.get(opts, :max_entries, 10_000)

    if byte_size(bytes) <= max_bytes and max_entries > 0 and
         prune(opts, max_bytes - byte_size(bytes), max_entries - 1) do
      temporary = path <> ".tmp-#{System.unique_integer([:positive])}"

      try do
        with :ok <- File.mkdir_p(Path.dirname(path)),
             :ok <- File.write(temporary, bytes, [:binary, :exclusive]),
             :ok <- File.rename(temporary, path) do
          :ok
        else
          {:error, reason} ->
            Logger.warning("Image cache publication failed",
              reason: Streamix.SafeLog.redact_inspect(reason)
            )
        end
      after
        File.rm(temporary)
      end
    end
  end

  defp prune(opts, bytes_budget, entry_budget) do
    opts[:cache_dir]
    |> Path.join("**/*.jpg")
    |> Path.wildcard()
    |> Enum.flat_map(fn path ->
      case File.stat(path, time: :posix) do
        {:ok, stat} -> [{path, stat}]
        _ -> []
      end
    end)
    |> Enum.sort_by(fn {_path, stat} -> stat.mtime end, :desc)
    |> Enum.reduce({0, 0}, fn entry, used ->
      retain_or_remove(entry, used, opts, bytes_budget, entry_budget)
    end)
    |> then(fn {bytes, entries} -> bytes <= bytes_budget and entries <= entry_budget end)
  end

  defp retain_or_remove({path, stat}, {bytes, entries}, opts, bytes_budget, entry_budget) do
    retained = {bytes + stat.size, entries + 1}

    if fresh?(stat, opts) and bytes + stat.size <= bytes_budget and entries < entry_budget do
      retained
    else
      case File.rm(path) do
        :ok -> {bytes, entries}
        {:error, :enoent} -> {bytes, entries}
        {:error, _reason} -> retained
      end
    end
  end

  defp cache_path(key, opts) do
    hash = :crypto.hash(:sha256, key) |> Base.encode16(case: :lower)
    <<a::binary-2, b::binary-2, _rest::binary>> = hash
    Path.join([opts[:cache_dir], a, b, hash <> ".jpg"])
  end
end
