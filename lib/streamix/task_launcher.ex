defmodule Streamix.TaskLauncher do
  @moduledoc false

  def start_child(fun) when is_function(fun, 0) do
    Task.Supervisor.start_child(Streamix.TaskSupervisor, fun)
  end
end
