defmodule Smell.Check.Design.BooleanObsession do
  use Credo.Check,
    base_priority: :normal,
    tags: [:anti_pattern],
    param_defaults: [exclude_test_files: true],
    docs_uri: "https://hexdocs.pm/elixir/design-anti-patterns.html#boolean-obsession",
    explanations: [
      check: """
      Use one option that takes an atom instead of boolean options with
      overlapping states.

      This is the "Boolean obsession" anti-pattern from the official Elixir
      documentation. Booleans are fine by themselves, but when two or more
      boolean options configure the same behavior, their states overlap.
      Below, `:editor` has no effect when `:admin` is set:

          def process(invoice, options \\\\ []) do
            cond do
              options[:admin] -> approve(invoice)
              options[:editor] -> review(invoice)
              true -> invoice
            end
          end

      A single option with atom values makes the states explicit:

          def process(invoice, options \\\\ []) do
            case Keyword.get(options, :role, :default) do
              :admin -> approve(invoice)
              :editor -> review(invoice)
              :default -> invoice
            end
          end

      An option is read with `options[:key]`, `Keyword.get(options, :key)` or
      `Keyword.get(options, :key, boolean)`, or through a variable bound to
      one of those or to `Keyword.pop(options, :key, boolean)`, where
      `options` is a parameter of the function. Reported:

        * a `cond` whose conditions read two or more of these options
        * a `case` on a tuple of two or more of these options, with `true`
          or `false` in the patterns for each of them

      Not reported:

        * an option whose value the `cond` branch uses, such as
          `opts[:values] -> list(opts[:values])`, which is not a boolean
        * struct and map fields (`user.admin?`, `Map.get/3`), options with
          a default that is not a boolean, options of a local variable (such
          as the result of `OptionParser.parse/2`), and conditions that
          combine options (`opts[:a] and opts[:b]`)
        * boolean fields of structs and schemas, where the check cannot tell
          whether the states overlap
        * files under `test/`, by default

      This check is opt-in: the Smell plugin does not enable it. Add it to
      the `checks` of your `.credo.exs`:

          checks: %{extra: [{Smell.Check.Design.BooleanObsession, []}]}
      """,
      params: [
        exclude_test_files: "Skip files under `test/`."
      ]
    ]

  alias Smell.Check.Helpers

  @defs [:def, :defp, :defmacro, :defmacrop]

  # Functions that read the value of an option, besides `options[:key]`.
  @keyword_reads [:get, :get_lazy, :fetch, :fetch!, :pop, :pop!, :pop_lazy]

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

  defp traverse({kind, _, [head, body]} = ast, issues, issue_meta)
       when kind in @defs and is_list(body) do
    case parameters(head) do
      [] ->
        {ast, issues}

      parameters ->
        flags = flag_variables(body, parameters)
        context = {parameters, flags, issue_meta}

        {ast, walk(body, issues, &find(&1, &2, context))}
    end
  end

  defp traverse(ast, issues, _issue_meta), do: {ast, issues}

  defp parameters({:when, _, [head | _]}), do: parameters(head)

  defp parameters({name, _, args}) when is_atom(name) and is_list(args) do
    for arg <- args, name = parameter(arg), do: name
  end

  defp parameters(_head), do: []

  defp parameter({:\\, _, [arg, _default]}), do: parameter(arg)
  defp parameter({:=, _, [left, right]}), do: parameter(left) || parameter(right)
  defp parameter({name, _, context}) when is_atom(name) and is_atom(context), do: name
  defp parameter(_arg), do: nil

  # Walks the body of a function, without the functions defined inside it
  # (in a `quote`), which have parameters of their own.
  defp walk(body, acc, fun) do
    body
    |> Macro.prewalk(acc, fn
      {kind, _, args}, acc when kind in @defs and is_list(args) -> {nil, acc}
      ast, acc -> fun.(ast, acc)
    end)
    |> elem(1)
  end

  # Variables bound to an option: `admin? = opts[:admin]` and
  # `{admin?, opts} = Keyword.pop(opts, :admin, false)`.
  defp flag_variables(body, parameters) do
    walk(body, %{}, fn
      {:=, _, [{name, _, context}, value]} = ast, flags when is_atom(name) and is_atom(context) ->
        {ast, put_flag(flags, name, option(value, parameters))}

      {:=, _, [{{name, _, context}, _rest}, value]} = ast, flags
      when is_atom(name) and is_atom(context) ->
        {ast, put_flag(flags, name, popped_option(value, parameters))}

      ast, flags ->
        {ast, flags}
    end)
  end

  defp put_flag(flags, _name, nil), do: flags
  defp put_flag(flags, name, option), do: Map.put(flags, name, option)

  defp find({:cond, meta, [[do: clauses]]} = ast, issues, {parameters, flags, issue_meta})
       when is_list(clauses) do
    options = Enum.flat_map(clauses, &condition_flag(&1, parameters, flags))

    {ast, add_issues(issues, issue_meta, "cond", meta, options)}
  end

  defp find(
         {:case, meta, [subject, [do: clauses]]} = ast,
         issues,
         {parameters, flags, issue_meta}
       )
       when is_list(clauses) do
    elements = tuple_elements(subject)
    options = Enum.map(elements, &flag(&1, parameters, flags))

    if length(elements) >= 2 and Enum.all?(options) and
         booleans_in_patterns?(clauses, length(elements)) do
      {ast, add_issues(issues, issue_meta, "case", meta, options)}
    else
      {ast, issues}
    end
  end

  defp find(ast, issues, _context), do: {ast, issues}

  # The option that a `cond` clause reads, unless the branch uses its value.
  defp condition_flag({:->, _, [[condition], branch]}, parameters, flags) do
    case flag(condition, parameters, flags) do
      nil -> []
      option -> if uses?(branch, option, flags), do: [], else: [option]
    end
  end

  defp condition_flag(_clause, _parameters, _flags), do: []

  # The option that a condition or a `case` element reads, as `{parameter, key}`.
  defp flag({name, _, context}, _parameters, flags) when is_atom(name) and is_atom(context),
    do: Map.get(flags, name)

  defp flag({op, _, [left, right]}, parameters, flags)
       when op in [:==, :===] and is_boolean(right),
       do: flag(left, parameters, flags)

  defp flag(ast, parameters, _flags), do: option(ast, parameters)

  defp option({{:., _, [Access, :get]}, _, [{name, _, context}, key]}, parameters)
       when is_atom(name) and is_atom(context),
       do: option_of(name, key, parameters)

  defp option(
         {{:., _, [{:__aliases__, _, [:Keyword]}, :get]}, _, [{name, _, context}, key | default]},
         parameters
       )
       when is_atom(name) and is_atom(context) do
    if boolean_default?(default), do: option_of(name, key, parameters)
  end

  defp option(_ast, _parameters), do: nil

  defp popped_option(
         {{:., _, [{:__aliases__, _, [:Keyword]}, :pop]}, _, [{name, _, context}, key | default]},
         parameters
       )
       when is_atom(name) and is_atom(context) do
    if boolean_default?(default), do: option_of(name, key, parameters)
  end

  defp popped_option(_ast, _parameters), do: nil

  defp option_of(name, key, parameters) do
    if is_atom(key) and key not in [nil, true, false] and name in parameters, do: {name, key}
  end

  defp boolean_default?([]), do: true
  defp boolean_default?([default]), do: is_boolean(default) or is_nil(default)
  defp boolean_default?(_default), do: false

  # The branch uses the value of the option, so it is not a boolean.
  defp uses?(branch, {name, key}, flags) do
    variables = for {variable, {^name, ^key}} <- flags, do: variable

    walk(branch, false, fn
      ast, true -> {ast, true}
      {variable, _, context} = ast, false when is_atom(context) -> {ast, variable in variables}
      ast, false -> {ast, reads?(ast, name, key)}
    end)
  end

  defp reads?({{:., _, [Access, :get]}, _, [{name, _, _}, key]}, name, key), do: true

  defp reads?(
         {{:., _, [{:__aliases__, _, [:Keyword]}, fun]}, _, [{name, _, _}, key | _]},
         name,
         key
       )
       when fun in @keyword_reads,
       do: true

  defp reads?(_ast, _name, _key), do: false

  defp tuple_elements({:{}, _, elements}), do: elements
  defp tuple_elements({left, right}), do: [left, right]
  defp tuple_elements(_ast), do: []

  # Every element of the tuple is matched against `true` or `false` in some clause.
  defp booleans_in_patterns?(clauses, size) do
    patterns =
      for {:->, _, [[pattern], _]} <- clauses,
          elements = pattern |> without_guard() |> tuple_elements(),
          length(elements) == size,
          do: elements

    Enum.all?(0..(size - 1), fn index ->
      Enum.any?(patterns, &is_boolean(Enum.at(&1, index)))
    end)
  end

  defp without_guard({:when, _, [pattern | _]}), do: pattern
  defp without_guard(pattern), do: pattern

  # One issue per options parameter with two or more boolean options.
  defp add_issues(issues, issue_meta, trigger, meta, options) do
    options
    |> Enum.uniq()
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.filter(fn {_name, keys} -> length(keys) >= 2 end)
    |> Enum.reduce(issues, fn {name, keys}, issues ->
      [issue_for(issue_meta, trigger, meta, name, keys) | issues]
    end)
  end

  defp issue_for(issue_meta, trigger, meta, name, keys) do
    format_issue(
      issue_meta,
      message:
        "The boolean options #{to_sentence(keys)} of `#{name}` have overlapping states. " <>
          "Use one option that takes an atom instead.",
      trigger: trigger,
      line_no: meta[:line],
      column: meta[:column]
    )
  end

  defp to_sentence(keys) do
    {keys, [last]} = keys |> Enum.map(&"`#{inspect(&1)}`") |> Enum.split(-1)
    Enum.join(keys, ", ") <> " and " <> last
  end
end
