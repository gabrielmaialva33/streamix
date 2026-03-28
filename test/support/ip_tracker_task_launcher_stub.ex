defmodule Streamix.TestSupport.IpTrackerTaskLauncherStub do
  @moduledoc false

  def start_child(fun) when is_function(fun, 0) do
    send(test_pid(), {:ip_tracker_task_started, fun})
    result = fun.()
    send(test_pid(), {:ip_tracker_task_finished, result})
    {:ok, self()}
  end

  defp test_pid do
    Application.fetch_env!(:streamix, :ip_tracker_task_launcher_test_pid)
  end
end
