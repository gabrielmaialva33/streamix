defmodule Streamix.RuntimeRedisSafety do
  @moduledoc false

  @local_hosts ~w(localhost 127.0.0.1 ::1 redis streamix-redis)
  @remote_override "i-know-this-is-a-test-redis"
  @derived_test_database 15

  def remote_override, do: @remote_override

  def prepare_test_url!(redis_url, opts \\ []) when is_binary(redis_url) do
    uri = URI.parse(redis_url)
    host = normalize_host(uri.host)
    allowed_hosts = @local_hosts ++ validate_compose_hosts!(Keyword.get(opts, :allowed_hosts, []))
    local? = host in allowed_hosts
    explicit? = Keyword.get(opts, :explicit?, false)
    allow_remote? = Keyword.get(opts, :allow_remote?, false)

    validate_uri!(uri)

    uri =
      if local? and not explicit? do
        %{uri | path: "/#{@derived_test_database}"}
      else
        uri
      end

    database = database_number!(uri.path)

    cond do
      local? ->
        URI.to_string(uri)

      not allow_remote? ->
        raise """
        refusing to run tests against remote Redis host #{inspect(host)} (database #{database}).
        Set TEST_REDIS_URL to localhost/a Compose Redis, or explicitly set
        ALLOW_REMOTE_TEST_REDIS=#{@remote_override} for an intentional isolated remote test Redis.
        """

      not explicit? ->
        raise """
        refusing to infer a remote test Redis URL for host #{inspect(host)}.
        Set an explicit TEST_REDIS_URL with a non-zero Redis database.
        """

      database == 0 ->
        raise """
        refusing remote test Redis host #{inspect(host)} with database 0.
        An intentional remote test Redis must use a non-zero Redis database.
        """

      true ->
        URI.to_string(uri)
    end
  end

  defp validate_uri!(%URI{scheme: scheme, host: host})
       when scheme in ["redis", "rediss"] and is_binary(host) and host != "",
       do: :ok

  defp validate_uri!(_uri) do
    raise "refusing to run tests with an invalid Redis URL"
  end

  defp normalize_host(host) when is_binary(host), do: String.downcase(host)
  defp normalize_host(_host), do: nil

  defp database_number!(nil), do: 0
  defp database_number!(""), do: 0
  defp database_number!("/"), do: 0

  defp database_number!("/" <> database) do
    case Integer.parse(database) do
      {number, ""} when number >= 0 -> number
      _ -> raise "refusing to run tests with an invalid Redis database number"
    end
  end

  defp database_number!(_path) do
    raise "refusing to run tests with an invalid Redis database number"
  end

  defp validate_compose_hosts!(hosts) do
    Enum.map(hosts, fn host ->
      normalized = normalize_host(host)

      if is_binary(normalized) and
           Regex.match?(~r/\A[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\z/, normalized) do
        normalized
      else
        raise """
        refusing invalid TEST_REDIS_ALLOWED_HOSTS entry #{inspect(host)}.
        Extra allowlisted hosts must be local Compose service names, not IP addresses or domains.
        """
      end
    end)
  end
end
