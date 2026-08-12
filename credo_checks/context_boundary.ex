defmodule Streamix.CredoChecks.ContextBoundary do
  @moduledoc """
  Prevents delivery modules from reaching through Streamix context facades.

  Web code has no exceptions. Workers have a small explicit debt register for
  schemas and algorithms that still need purpose-built context entrypoints.
  """

  use Credo.Check,
    base_priority: :high,
    category: :design,
    explanations: [
      check: """
      Web modules and workers must call public context facades such as `Streamix.Iptv`.
      Reaching into schemas or internal modules couples the delivery layer to
      implementation details and makes context refactors unsafe.
      """
    ]

  alias Credo.IssueMeta

  @contexts ~w(Access Accounts AI Billing Gindex Iptv Qoe Queue Subtitles Torrent WatchParty)a

  # Temporary debt register. Schema access remains necessary in workers that
  # own Ecto queries; move those queries behind context entrypoints before
  # removing these entries.
  @worker_schema_allowlist ~w(
    Streamix.Iptv.Episode
    Streamix.Iptv.Movie
    Streamix.Iptv.MovieAsset
    Streamix.Iptv.Season
    Streamix.Iptv.Series
    Streamix.Iptv.SeriesAsset
  )

  # Algorithm/module injection still used by bounded ingestion workers. Unlike
  # a namespace-wide exception, this list rejects every new internal module by
  # default and makes the remaining migration debt reviewable.
  @worker_service_allowlist ~w(
    Streamix.AI.SemanticSearch
    Streamix.Gindex.AnimeMatcher
    Streamix.Gindex.ReleaseParser
    Streamix.Gindex.TmdbMatcher
    Streamix.Gindex.TomatoMatcher
    Streamix.Iptv.TmdbClient
  )

  @worker_internal_allowlist @worker_schema_allowlist ++ @worker_service_allowlist

  @impl Credo.Check
  def run(source_file, params \\ []) do
    if delivery_source?(source_file.filename) do
      issue_meta = IssueMeta.for(source_file, params)

      Credo.Code.prewalk(
        source_file,
        &traverse(&1, &2, issue_meta, source_file.filename)
      )
    else
      []
    end
  end

  defp traverse(
         {:alias, meta,
          [
            {{:., _, [{:__aliases__, _, [:Streamix, context] = base}, :{}]}, _, nested_modules}
          ]} = ast,
         issues,
         issue_meta,
         filename
       )
       when context in @contexts and nested_modules != [] do
    if grouped_alias_allowed?(filename, base, nested_modules) do
      {ast, issues}
    else
      trigger = "#{inspect_alias(base)}.{...}"
      {ast, [issue_for(trigger, meta[:line], issue_meta) | issues]}
    end
  end

  defp traverse(
         {:__aliases__, meta, [:Streamix, context, _ | _] = parts} = ast,
         issues,
         issue_meta,
         filename
       )
       when context in @contexts do
    if nested_module_allowed?(filename, parts) do
      {ast, issues}
    else
      trigger = inspect_alias(parts)
      {ast, [issue_for(trigger, meta[:line], issue_meta) | issues]}
    end
  end

  defp traverse(ast, issues, _issue_meta, _filename), do: {ast, issues}

  defp issue_for(trigger, line_no, issue_meta) do
    format_issue(
      issue_meta,
      message: "Call the public context facade instead of #{trigger}.",
      trigger: trigger,
      line_no: line_no
    )
  end

  defp inspect_alias(parts), do: Enum.join(parts, ".")

  defp grouped_alias_allowed?(filename, base, nested_modules) do
    Enum.all?(nested_modules, fn
      {:__aliases__, _, nested_parts} ->
        nested_module_allowed?(filename, base ++ nested_parts)

      _ ->
        false
    end)
  end

  defp nested_module_allowed?(filename, parts) do
    worker_source?(filename) and inspect_alias(parts) in @worker_internal_allowlist
  end

  defp delivery_source?(filename) do
    web_source?(filename) or worker_source?(filename)
  end

  defp web_source?(filename) when is_binary(filename) do
    normalized = String.replace(filename, "\\", "/")

    String.starts_with?(normalized, "lib/streamix_web/") or
      String.contains?(normalized, "/lib/streamix_web/")
  end

  defp web_source?(_filename), do: false

  defp worker_source?(filename) when is_binary(filename) do
    normalized = String.replace(filename, "\\", "/")

    String.starts_with?(normalized, "lib/streamix/workers/") or
      String.contains?(normalized, "/lib/streamix/workers/")
  end

  defp worker_source?(_filename), do: false
end
