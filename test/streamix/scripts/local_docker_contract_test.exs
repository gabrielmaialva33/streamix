defmodule Streamix.Scripts.LocalDockerContractTest do
  use ExUnit.Case, async: true
  @root Path.expand("../../..", __DIR__)

  @tag :tmp_dir
  test "browser runners reject remote contexts before builds, installs or containers", %{
    tmp_dir: dir
  } do
    File.write!(Path.join(dir, "docker"), "#!/bin/sh\nprintf '%s\\n' 'ssh://remote.invalid'\n")
    File.chmod!(Path.join(dir, "docker"), 0o755)
    File.write!(Path.join(dir, "node"), "#!/bin/sh\necho 'UNEXPECTED_NODE_CALL' >&2\nexit 91\n")
    File.chmod!(Path.join(dir, "node"), 0o755)

    for script <- [
          "test-playwright-docker.sh",
          "test-webkit-docker.sh",
          "test-mpegts-browser-gate.sh",
          "test-pwa-chromium.sh"
        ] do
      {output, status} =
        System.cmd("bash", [Path.join(@root, "scripts/#{script}")],
          env: [
            {"PATH", dir <> ":" <> System.get_env("PATH")},
            {"DOCKER_CONTEXT", "review-remote"},
            {"DOCKER_HOST", nil}
          ],
          stderr_to_stdout: true
        )

      assert status == 64, "#{script}: #{output}"
      assert output =~ "requires a local Docker endpoint"
      refute output =~ "UNEXPECTED_NODE_CALL"
    end
  end

  @tag :tmp_dir
  test "preflight honors explicit host and context precedence without connecting", %{tmp_dir: dir} do
    File.write!(Path.join(dir, "docker"), "#!/bin/sh\nprintf '%s\\n' 'ssh://remote.invalid'\n")
    File.chmod!(Path.join(dir, "docker"), 0o755)
    command = "source scripts/require-local-docker.sh; require_local_docker"

    env = [
      {"PATH", dir <> ":" <> System.get_env("PATH")},
      {"DOCKER_HOST", "unix:///run/docker.sock"},
      {"DOCKER_CONTEXT", nil}
    ]

    assert {"", 0} =
             System.cmd("bash", ["-c", command], cd: @root, env: env, stderr_to_stdout: true)

    {_output, status} =
      System.cmd("bash", ["-c", command],
        cd: @root,
        env: List.keystore(env, "DOCKER_CONTEXT", 0, {"DOCKER_CONTEXT", "remote"}),
        stderr_to_stdout: true
      )

    assert status == 64
  end
end
