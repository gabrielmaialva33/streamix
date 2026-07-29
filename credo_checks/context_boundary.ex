defmodule Streamix.CredoChecks.ContextBoundary do
  @moduledoc """
  Prevents web modules from reaching through Streamix context facades.
  """

  use Credo.Check,
    base_priority: :high,
    category: :design,
    explanations: [
      check: """
      Web modules must call public context facades such as `Streamix.Iptv`.
      Reaching into schemas or internal modules couples the delivery layer to
      implementation details and makes context refactors unsafe.
      """
    ]

  alias Credo.IssueMeta

  @contexts ~w(Access Accounts AI Billing Gindex Iptv Library Queue Torrent WatchParty)a

  @impl Credo.Check
  def run(source_file, params \\ []) do
    if web_source?(source_file.filename) do
      issue_meta = IssueMeta.for(source_file, params)
      Credo.Code.prewalk(source_file, &traverse(&1, &2, issue_meta))
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
         issue_meta
       )
       when context in @contexts and nested_modules != [] do
    trigger = "#{inspect_alias(base)}.{...}"
    {ast, [issue_for(trigger, meta[:line], issue_meta) | issues]}
  end

  defp traverse(
         {:__aliases__, meta, [:Streamix, context, _ | _] = parts} = ast,
         issues,
         issue_meta
       )
       when context in @contexts do
    trigger = inspect_alias(parts)
    {ast, [issue_for(trigger, meta[:line], issue_meta) | issues]}
  end

  defp traverse(ast, issues, _issue_meta), do: {ast, issues}

  defp issue_for(trigger, line_no, issue_meta) do
    format_issue(
      issue_meta,
      message: "Call the public context facade instead of #{trigger}.",
      trigger: trigger,
      line_no: line_no
    )
  end

  defp inspect_alias(parts), do: Enum.join(parts, ".")

  defp web_source?(filename) when is_binary(filename) do
    normalized = String.replace(filename, "\\", "/")

    String.starts_with?(normalized, "lib/streamix_web/") or
      String.contains?(normalized, "/lib/streamix_web/")
  end

  defp web_source?(_filename), do: false
end
