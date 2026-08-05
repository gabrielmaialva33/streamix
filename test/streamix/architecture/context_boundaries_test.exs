defmodule Streamix.ContextBoundariesTest do
  use ExUnit.Case, async: true

  @contexts ~w(access accounts ai billing gindex iptv library qoe queue torrent watch_party)

  # Existing violations are an explicit debt ledger. New entries fail CI, and
  # removing an old violation also fails until this list is ratcheted down.
  @baseline MapSet.new([
              "lib/streamix/access.ex alias Streamix.Accounts.User",
              "lib/streamix/access/role_permission.ex alias Streamix.Accounts.Role",
              "lib/streamix/access/user_permission.ex alias Streamix.Accounts.User",
              "lib/streamix/billing/admin.ex alias Streamix.Accounts.User",
              "lib/streamix/billing/billing_customer.ex alias Streamix.Accounts.User",
              "lib/streamix/billing/checkout_session.ex alias Streamix.Accounts.User",
              "lib/streamix/billing/customers.ex alias Streamix.Accounts.User",
              "lib/streamix/billing/entitlements.ex alias Streamix.Accounts.User",
              "lib/streamix/billing/invoice.ex alias Streamix.Accounts.User",
              "lib/streamix/billing/payment.ex alias Streamix.Accounts.User",
              "lib/streamix/billing/payments.ex alias Streamix.Accounts.User",
              "lib/streamix/billing/playback_session.ex alias Streamix.Accounts.User",
              "lib/streamix/billing/playback_sessions.ex alias Streamix.Accounts.User",
              "lib/streamix/billing/stripe.ex alias Streamix.Accounts.User",
              "lib/streamix/billing/stripe/events.ex alias Streamix.Accounts.User",
              "lib/streamix/billing/subscription.ex alias Streamix.Accounts.User",
              "lib/streamix/billing/subscriptions.ex alias Streamix.Accounts.User",
              "lib/streamix/iptv/engagement/favorite.ex alias Streamix.Accounts.User",
              "lib/streamix/iptv/engagement/watch_event.ex alias Streamix.Accounts.User",
              "lib/streamix/iptv/engagement/watch_progress.ex alias Streamix.Accounts.User",
              "lib/streamix/iptv/providers/global_provider.ex alias Streamix.Accounts.User",
              "lib/streamix/iptv/providers/provider.ex alias Streamix.Accounts.User",
              "lib/streamix/iptv/streaming/stream_proxy.ex alias Streamix.Gindex.UrlCache",
              "lib/streamix/iptv/sync/cleanup.ex alias Streamix.WatchParty.Room",
              "lib/streamix/iptv/tmdb_client/transport.ex alias Streamix.Gindex.Pacer",
              "lib/streamix/watch_party/room.ex alias Streamix.Iptv.CatalogItem"
            ])

  test "web and contexts only alias another context through its public facade" do
    observed = observed_violations()
    observed_ids = observed |> Map.keys() |> MapSet.new()

    unexpected = MapSet.difference(observed_ids, @baseline)
    stale = MapSet.difference(@baseline, observed_ids)

    assert MapSet.size(unexpected) == 0,
           """
           New cross-context aliases bypass public facades:
           #{format_violations(unexpected, observed)}
           """

    assert MapSet.size(stale) == 0,
           """
           Context boundary debt was removed. Ratchet @baseline down:
           #{stale |> Enum.sort() |> Enum.join("\n")}
           """
  end

  defp observed_violations do
    "lib/**/*.ex"
    |> Path.wildcard()
    |> Enum.reduce(%{}, fn file, violations ->
      case source_context(file) do
        nil -> violations
        source -> collect_file_violations(file, source, violations)
      end
    end)
  end

  defp collect_file_violations(file, source, violations) do
    ast = file |> File.read!() |> Code.string_to_quoted!()

    {_ast, aliases} =
      Macro.prewalk(ast, [], fn
        {:alias, metadata, [target | _options]} = node, aliases ->
          found = for parts <- expand_alias(target), do: {metadata[:line], parts}
          {node, found ++ aliases}

        node, aliases ->
          {node, aliases}
      end)

    Enum.reduce(aliases, violations, fn {line, parts}, acc ->
      case forbidden_alias(source, parts) do
        nil ->
          acc

        module ->
          id = "#{file} alias #{module}"
          Map.update(acc, id, [line], &[line | &1])
      end
    end)
  end

  defp expand_alias({:__aliases__, _metadata, parts}), do: [parts]

  defp expand_alias(
         {{:., _dot_metadata, [{:__aliases__, _prefix_metadata, prefix}, :{}]}, _call_metadata,
          suffixes}
       ) do
    for {:__aliases__, _metadata, suffix} <- suffixes, do: prefix ++ suffix
  end

  defp expand_alias(_target), do: []

  defp forbidden_alias(source, [:Streamix, target | nested]) when nested != [] do
    target_context = target |> Atom.to_string() |> Macro.underscore()

    if target_context in @contexts and target_context != source do
      ["Streamix", Atom.to_string(target) | Enum.map(nested, &Atom.to_string/1)]
      |> Enum.join(".")
    end
  end

  defp forbidden_alias(_source, _parts), do: nil

  defp source_context("lib/streamix_web/" <> _path), do: "web"

  defp source_context("lib/streamix/" <> path) do
    context =
      path
      |> String.split("/", parts: 2)
      |> List.first()
      |> Path.rootname()

    if context in @contexts, do: context
  end

  defp source_context(_file), do: nil

  defp format_violations(ids, observed) do
    ids
    |> Enum.sort()
    |> Enum.map_join("\n", fn id ->
      lines = observed |> Map.fetch!(id) |> Enum.sort() |> Enum.join(",")
      "#{id} (lines #{lines})"
    end)
  end
end
