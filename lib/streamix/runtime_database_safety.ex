defmodule Streamix.RuntimeDatabaseSafety do
  @moduledoc false

  @local_hosts ~w(localhost 127.0.0.1 ::1 postgres streamix-postgres)
  @remote_override "i-know-this-is-a-test-database"

  def remote_override, do: @remote_override

  def validate_test_url!(database_url, opts \\ [])

  def validate_test_url!(nil, _opts), do: nil

  def validate_test_url!(database_url, opts) when is_binary(database_url) do
    uri = URI.parse(database_url)
    host = normalize_host(uri.host)
    database = database_name(uri.path)
    allowed_hosts = @local_hosts ++ validate_compose_hosts!(Keyword.get(opts, :allowed_hosts, []))

    validate_test_database_name!(database)

    if Keyword.get(opts, :allow_remote?, false) or host in allowed_hosts do
      database_url
    else
      raise """
      refusing to run tests against remote database host #{inspect(host)} (database #{inspect(database)}).
      Set TEST_DATABASE_URL to localhost/a Compose database, or explicitly set
      ALLOW_REMOTE_TEST_DATABASE=#{@remote_override} for an intentional isolated remote test database.
      """
    end
  end

  defp normalize_host(host) when is_binary(host), do: String.downcase(host)
  defp normalize_host(_host), do: nil

  defp database_name("/" <> database) when database != "", do: URI.decode(database)
  defp database_name(_path), do: nil

  defp validate_compose_hosts!(hosts) do
    Enum.map(hosts, fn host ->
      normalized = normalize_host(host)

      if is_binary(normalized) and
           Regex.match?(~r/\A[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\z/, normalized) do
        normalized
      else
        raise """
        refusing invalid TEST_DATABASE_ALLOWED_HOSTS entry #{inspect(host)}.
        Extra allowlisted hosts must be local Compose service names, not IP addresses or domains.
        """
      end
    end)
  end

  defp validate_test_database_name!(database) when is_binary(database) do
    if Regex.match?(~r/_test\d*\z/, database) do
      :ok
    else
      raise """
      refusing to run tests against database #{inspect(database)}.
      Test database names must end in _test (optionally followed by a partition number).
      """
    end
  end

  defp validate_test_database_name!(_database) do
    raise "refusing to run tests with a database URL that has no database name"
  end
end
