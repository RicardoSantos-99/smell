defmodule Smell.Check.Design.UseInsteadOfImport do
  use Credo.Check,
    base_priority: :normal,
    tags: [:anti_pattern],
    param_defaults: [exclude_test_files: true],
    docs_uri: "https://hexdocs.pm/elixir/macro-anti-patterns.html#use-instead-of-import",
    explanations: [
      check: """
      Do not define `__using__/1` when `import`, `alias` or `require` is enough.

      This is the "`use` instead of `import`" anti-pattern from the official
      Elixir documentation. `import` and `alias` are lexical and explicit,
      while `use` can inject any code into the caller. When `__using__/1`
      only adds directives, callers cannot see what their module depends on,
      and an injected import can conflict with their own functions:

          defmodule Library do
            defmacro __using__(_opts) do
              quote do
                import Library
                import ModuleA
              end
            end
          end

          defmodule ClientApp do
            use Library

            # error: imported ModuleA.foo/0 conflicts with local function
            def foo, do: "local"
          end

      Remove `__using__/1` and let callers write the directives they need:

          defmodule ClientApp do
            import Library
          end

      A module is reported when every clause of its `__using__/1` returns a
      `quote` with only `import`, `alias` and `require` directives.

      Not reported:

        * `__using__/1` that injects anything else (functions, attributes,
          `@behaviour`, another `use`), or that does not end in a `quote`
        * a deprecated `__using__/1` (marked with `@deprecated` or calling
          `IO.warn`), kept only until callers move to `import`
        * files under `test/`, by default

      When `use` is needed, the documentation recommends a
      "#### `use MyModule`" admonition in the `@moduledoc` that lists what it
      changes in the caller.
      """,
      params: [
        exclude_test_files: "Skip files under `test/`."
      ]
    ]

  alias Smell.Check.Helpers

  @directives [:import, :alias, :require]

  # How many directives the message lists.
  @max_listed 3

  @doc false
  @impl true
  def run(%SourceFile{} = source_file, params) do
    if Params.get(params, :exclude_test_files, __MODULE__) and
         Helpers.test_file?(source_file.filename) do
      []
    else
      issue_meta = IssueMeta.for(source_file, params)

      source_file
      |> Credo.Code.prewalk(&collect_module_bodies/2)
      |> Enum.reverse()
      |> Enum.flat_map(&check_module(&1, issue_meta))
    end
  end

  defp collect_module_bodies({:defmodule, _, [_name, [do: body]]} = ast, acc),
    do: {ast, [statements(body) | acc]}

  defp collect_module_bodies(ast, acc), do: {ast, acc}

  defp check_module(statements, issue_meta) do
    clauses = using_clauses(statements)

    with [{meta, _deprecated?, _directives} | _] <- clauses,
         false <- Enum.any?(clauses, fn {_, deprecated?, _} -> deprecated? end),
         true <- Enum.all?(clauses, fn {_, _, directives} -> directives != nil end) do
      directives = Enum.flat_map(clauses, fn {_, _, directives} -> directives end)
      [issue_for(issue_meta, meta, directives)]
    else
      _ -> []
    end
  end

  # Returns `{meta, deprecated?, directives}` for each `defmacro __using__`
  # clause, with `nil` directives when the clause injects anything else.
  defp using_clauses(statements) do
    statements
    |> Enum.with_index()
    |> Enum.flat_map(fn
      {{:defmacro, _, [head, body]}, index} when is_list(body) ->
        case using_meta(head) do
          nil ->
            []

          meta ->
            body = body |> keyword_get(:do) |> statements()
            deprecated? = deprecated_attribute?(statements, index) or Enum.any?(body, &warning?/1)
            [{meta, deprecated?, quoted_directives(body)}]
        end

      _ ->
        []
    end)
  end

  defp using_meta({:when, _, [head | _]}), do: using_meta(head)
  defp using_meta({:__using__, meta, args}) when is_list(args), do: meta
  defp using_meta(_head), do: nil

  # `@deprecated` among the attributes right before the clause.
  defp deprecated_attribute?(statements, index) do
    statements
    |> Enum.take(index)
    |> Enum.reverse()
    |> Enum.take_while(&match?({:@, _, [{name, _, _}]} when is_atom(name), &1))
    |> Enum.any?(&match?({:@, _, [{:deprecated, _, _}]}, &1))
  end

  defp warning?({{:., _, [{:__aliases__, _, [:IO]}, :warn]}, _, _args}), do: true
  defp warning?(_statement), do: false

  # The directives of the `quote` that ends the clause, or `nil` when the
  # clause does not end in a `quote` with only directives.
  defp quoted_directives(body) do
    with {:quote, _, [_ | _] = args} <- List.last(body),
         [_ | _] = directives <- args |> List.last() |> keyword_get(:do) |> statements(),
         true <- Enum.all?(directives, &directive?/1) do
      directives
    else
      _ -> nil
    end
  end

  defp directive?({kind, _, [_ | _]}) when kind in @directives, do: true
  defp directive?(_statement), do: false

  defp statements({:__block__, _, statements}), do: statements
  defp statements(statement), do: [statement]

  defp keyword_get(list, key) when is_list(list) do
    if Keyword.keyword?(list), do: Keyword.get(list, key)
  end

  defp keyword_get(_ast, _key), do: nil

  defp issue_for(issue_meta, meta, directives) do
    format_issue(
      issue_meta,
      message:
        "`__using__/1` only injects #{describe(directives)}. " <>
          "Remove it and let callers write the directives they need instead of `use`.",
      trigger: "__using__",
      line_no: meta[:line],
      column: meta[:column]
    )
  end

  defp describe(directives) do
    names = directives |> Enum.map(&directive_name/1) |> Enum.uniq()
    {listed, rest} = Enum.split(names, @max_listed)
    listed = Enum.map_join(listed, ", ", &"`#{&1}`")

    case length(rest) do
      0 -> listed
      count -> "#{listed} and #{count} more"
    end
  end

  # `alias MyApp.{A, B}` is shortened to `alias MyApp.{...}`.
  defp directive_name({kind, _, [{{:., _, [base, :{}]}, _, _children} | _]}),
    do: "#{kind} #{Macro.to_string(base)}.{...}"

  defp directive_name({kind, _, [target | _]}), do: "#{kind} #{Macro.to_string(target)}"
end
