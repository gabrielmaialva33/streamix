defmodule Streamix.Accounts.IpTrackerTest do
  use Streamix.DataCase

  import Plug.Conn
  import Streamix.AccountsFixtures

  alias Streamix.Accounts.{AccessLog, IpTracker}

  describe "log_access_async/2" do
    setup do
      previous_launcher =
        Application.get_env(:streamix, :ip_tracker_task_launcher, Streamix.TaskLauncher)

      previous_test_pid = Application.get_env(:streamix, :ip_tracker_task_launcher_test_pid)

      Application.put_env(
        :streamix,
        :ip_tracker_task_launcher,
        Streamix.TestSupport.IpTrackerTaskLauncherStub
      )

      Application.put_env(:streamix, :ip_tracker_task_launcher_test_pid, self())

      on_exit(fn ->
        Application.put_env(:streamix, :ip_tracker_task_launcher, previous_launcher)

        if previous_test_pid do
          Application.put_env(:streamix, :ip_tracker_task_launcher_test_pid, previous_test_pid)
        else
          Application.delete_env(:streamix, :ip_tracker_task_launcher_test_pid)
        end
      end)

      :ok
    end

    test "launches access logging through the configured launcher and persists the record" do
      user = user_fixture()

      conn =
        Plug.Test.conn(:get, "/login")
        |> put_req_header("user-agent", "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)")
        |> put_req_header("x-real-ip", "203.0.113.10")
        |> put_req_header("cf-ipcountry", "BR")
        |> put_req_header("cf-ipcity", "Sao Paulo")

      assert :ok = IpTracker.log_access_async(conn, user.id)
      assert_receive {:ip_tracker_task_started, fun} when is_function(fun, 0)
      assert_receive {:ip_tracker_task_finished, {:ok, %AccessLog{}}}

      assert %AccessLog{} = access_log = Repo.one!(AccessLog)
      assert access_log.user_id == user.id
      assert access_log.ip_address == "203.0.113.10"
      assert access_log.path == "/login"
      assert access_log.method == "GET"
      assert access_log.country == "BR"
      assert access_log.city == "Sao Paulo"
      assert access_log.device_type == "desktop"
      assert access_log.os == "macOS"
      assert access_log.browser == "Other"
    end
  end
end
