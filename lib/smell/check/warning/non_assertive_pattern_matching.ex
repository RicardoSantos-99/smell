defmodule Smell.Check.Warning.NonAssertivePatternMatching do
  use Credo.Check,
    base_priority: :normal,
    tags: [:anti_pattern],
    param_defaults: [exclude_test_files: true],
    docs_uri: "https://hexdocs.pm/elixir/code-anti-patterns.html#non-assertive-pattern-matching",
    explanations: [
      check: """
      Match the error values of a `case` explicitly instead of falling back to `_`.

      This is the "Non-assertive pattern matching" anti-pattern from the
      official Elixir documentation. When a function returns `{:ok, ...}` or
      `{:error, ...}`, a `_` clause hides which values the code expects, and
      it also hides any value the function starts to return in the future:

          case some_function(arg) do
            {:ok, value} -> # ...
            _ -> # ...
          end

      Match both patterns instead (`:error` for functions such as
      `Map.fetch/2`), so an unexpected value raises a `CaseClauseError`:

          case some_function(arg) do
            {:ok, value} -> # ...
            {:error, _} -> # ...
          end

      A `case` is reported when it has an `{:ok, ...}` clause that matches any
      value (only variables inside the tuple, no guard), followed by a clause
      that is only `_` or `_name`, and no clause for `:error` or
      `{:error, ...}`.

      Not reported:

        * `{:ok, ...}` clauses that match specific values or have a guard,
          because `_` then also catches the other `{:ok, ...}` values
        * a catch-all that ends in `raise`, `reraise` or `Mix.raise`, which
          already crashes on unexpected values
        * a catch-all variable without underscore, such as `error -> error`,
          which passes the value on
        * `with` and its `else` block, `receive` and multi-clause functions
        * files under `test/`, by default
      """,
      params: [
        exclude_test_files: "Skip files under `test/`."
      ]
    ]

  alias Smell.Check.Helpers

  # Names that look like underscored variables but match a fixed value.
  @special_forms [:__MODULE__, :__DIR__, :__ENV__, :__CALLER__, :__STACKTRACE__]

  @doc false
  @impl true
  def run(%SourceFile{} = source_file, params) do
    if Params.get(params, :exclude_test_files, __MODULE__) and
         Helpers.test_file?(source_file.filename) do
      []
    else
      issue_meta = IssueMeta.for(source_file, params)

      Credo.Code.prewalk(source_file, &traverse(&1, &2, issue_meta))
    end
  end

  # `case subject do ... end`, or `subject |> case do ... end` without the subject.
  defp traverse({:case, _meta, [_ | _] = args} = ast, issues, issue_meta) do
    with [do: clauses] when is_list(clauses) <- List.last(args),
         {name, meta} <- catch_all_after_ok(clauses) do
      {ast, [issue_for(issue_meta, name, meta) | issues]}
    else
      _ -> {ast, issues}
    end
  end

  defp traverse(ast, issues, _issue_meta), do: {ast, issues}

  # The first catch-all clause after an `{:ok, ...}` clause that matches any
  # value, when no clause matches an error and the catch-all does not raise.
  defp catch_all_after_ok(clauses) do
    clauses = for {:->, _, [[pattern], body]} <- clauses, do: {pattern, body}
    patterns = Enum.map(clauses, &elem(&1, 0))

    with false <- Enum.any?(patterns, &error_pattern?/1),
         index when is_integer(index) <- Enum.find_index(patterns, &any_ok?/1),
         {pattern, body} <- clauses |> Enum.drop(index + 1) |> Enum.find(&catch_all(elem(&1, 0))),
         false <- raises?(body) do
      catch_all(pattern)
    else
      _ -> nil
    end
  end

  defp any_ok?({:=, _, [left, right]}), do: any_ok?(left) or any_ok?(right)
  defp any_ok?({:ok, value}), do: variable?(value)
  defp any_ok?({:{}, _, [:ok | values]}), do: Enum.all?(values, &variable?/1)
  defp any_ok?(_pattern), do: false

  defp error_pattern?({:when, _, [pattern | _]}), do: error_pattern?(pattern)
  defp error_pattern?({:=, _, [left, right]}), do: error_pattern?(left) or error_pattern?(right)
  defp error_pattern?(:error), do: true
  defp error_pattern?({:error, _}), do: true
  defp error_pattern?({:{}, _, [:error | _]}), do: true
  defp error_pattern?(_pattern), do: false

  defp catch_all({name, meta, _context} = pattern) do
    if variable?(pattern) and String.starts_with?(Atom.to_string(name), "_"), do: {name, meta}
  end

  defp catch_all(_pattern), do: nil

  defp raises?({:__block__, _, [_ | _] = expressions}), do: raises?(List.last(expressions))
  defp raises?({kind, _, [_ | _]}) when kind in [:raise, :reraise], do: true
  defp raises?({{:., _, [{:__aliases__, _, [:Mix]}, :raise]}, _, _}), do: true
  defp raises?(_expression), do: false

  defp variable?({name, _meta, context}) when is_atom(name) and is_atom(context),
    do: name not in @special_forms

  defp variable?(_pattern), do: false

  defp issue_for(issue_meta, name, meta) do
    format_issue(
      issue_meta,
      message:
        "`case` matches `{:ok, ...}` and then everything else with `#{name}`. " <>
          "Match the error values explicitly, like `{:error, _}` or `:error`.",
      trigger: Atom.to_string(name),
      line_no: meta[:line],
      column: meta[:column]
    )
  end
end
