defmodule Smell.Check.Refactor.SendingUnnecessaryData do
  use Credo.Check,
    base_priority: :normal,
    tags: [:anti_pattern],
    param_defaults: [exclude_test_files: true],
    docs_uri: "https://hexdocs.pm/elixir/process-anti-patterns.html#sending-unnecessary-data",
    explanations: [
      check: """
      Read the fields a process needs before the function that starts it.

      This is the "Sending unnecessary data" anti-pattern from the official
      Elixir documentation. A message is copied to the process that receives
      it, and so is an anonymous function given to `spawn/1` or
      `Task.async/1`, with every variable it captures. Below, the function
      only needs the IP address, but it captures `conn`, so the whole
      connection, with its body and params, is copied to the new process:

          spawn(fn -> log_request_ip(conn.remote_ip) end)

      Reading the field first copies only the IP address:

          ip_address = conn.remote_ip
          spawn(fn -> log_request_ip(ip_address) end)

      Reported: a variable that an anonymous function (`fn` or `&`) captures
      only to read its fields (`conn.remote_ip`, `state.config.timeout`), when
      the function is given to:

        * `spawn/1`, `spawn_link/1`, `spawn_monitor/1`, `Process.spawn/2` and
          `Node.spawn/2`
        * `Task.async/1`, `Task.start/1`, `Task.start_link/1`,
          `Task.async_stream/3` and the same functions of `Task.Supervisor`
        * the `Agent` functions that take a function (`Agent.start_link/2`,
          `Agent.get/3`, `Agent.update/3`, ...), which runs in the agent
        * `start_async/3` and `assign_async/3` of Phoenix LiveView, except for
          `socket`, which LiveView already warns about

      Not reported:

        * a variable that the function also uses whole (`log(conn)`), matches,
          pins or updates: the check cannot tell how much of it the process
          needs
        * map access with `conn[:key]` or `Map.get/2`, which takes the whole
          map as an argument
        * messages sent with `send/2` or `GenServer.call/3`, since the check
          cannot tell which part the receiver uses
        * function references (`&Mod.fun/1`) and module, function and
          arguments, which capture nothing
        * files under `test/`, by default

      This check is opt-in: the Smell plugin does not enable it. Add it to
      the `checks` of your `.credo.exs`:

          checks: %{extra: [{Smell.Check.Refactor.SendingUnnecessaryData, []}]}
      """,
      params: [
        exclude_test_files: "Skip files under `test/`."
      ]
    ]

  alias Smell.Check.Helpers

  # The position of the function argument, counting the piped value, for each
  # function that runs it in another process. `nil` is a local call.
  @spawns %{
    {nil, :spawn} => 0,
    {nil, :spawn_link} => 0,
    {nil, :spawn_monitor} => 0,
    {[:Kernel], :spawn} => 0,
    {[:Kernel], :spawn_link} => 0,
    {[:Kernel], :spawn_monitor} => 0,
    {:erlang, :spawn} => 0,
    {:erlang, :spawn_link} => 0,
    {:erlang, :spawn_monitor} => 0,
    {:erlang, :spawn_opt} => 0,
    {[:Process], :spawn} => 0,
    {[:Node], :spawn} => 1,
    {[:Node], :spawn_link} => 1,
    {[:Node], :spawn_monitor} => 1,
    {[:Task], :async} => 0,
    {[:Task], :start} => 0,
    {[:Task], :start_link} => 0,
    {[:Task], :async_stream} => 1,
    {[:Task, :Supervisor], :async} => 1,
    {[:Task, :Supervisor], :async_nolink} => 1,
    {[:Task, :Supervisor], :start_child} => 1,
    {[:Task, :Supervisor], :async_stream} => 2,
    {[:Task, :Supervisor], :async_stream_nolink} => 2,
    {[:Agent], :start} => 0,
    {[:Agent], :start_link} => 0,
    {[:Agent], :get} => 1,
    {[:Agent], :update} => 1,
    {[:Agent], :get_and_update} => 1,
    {[:Agent], :cast} => 1
  }

  # LiveView warns when the function captures `socket`.
  @live_view_spawns %{
    {nil, :start_async} => 2,
    {nil, :assign_async} => 2,
    {[:Phoenix, :LiveView], :start_async} => 2,
    {[:Phoenix, :LiveView], :assign_async} => 2
  }

  @piped {:__smell_piped__, [], __MODULE__}

  @doc false
  @impl true
  def run(%SourceFile{} = source_file, params) do
    if Params.get(params, :exclude_test_files, __MODULE__) and
         Helpers.test_file?(source_file.filename) do
      []
    else
      issue_meta = IssueMeta.for(source_file, params)

      source_file
      |> Credo.Code.prewalk(&traverse/2)
      |> Enum.reverse()
      |> Enum.uniq_by(fn {_call, name, meta, _fields} -> {name, meta[:line], meta[:column]} end)
      |> Enum.map(&issue_for(issue_meta, &1))
    end
  end

  # In `list |> Task.async_stream(fun)`, the piped value is the first argument.
  defp traverse({:|>, meta, [left, {call, call_meta, args}]}, captures) when is_list(args) do
    {{:|>, meta, [left, {call, call_meta, [@piped | args]}]}, captures}
  end

  defp traverse({call, _meta, args} = ast, captures) when is_list(args) do
    with {name, index, ignored} <- target(call),
         fun = Enum.at(args, index),
         true <- closure?(fun) do
      function = "#{name}/#{length(args)}"

      captures =
        fun
        |> field_only_captures()
        |> Enum.reject(fn {variable, _meta, _fields} -> variable in ignored end)
        |> Enum.reduce(captures, fn {variable, meta, fields}, captures ->
          [{function, variable, meta, fields} | captures]
        end)

      {ast, captures}
    else
      _ -> {ast, captures}
    end
  end

  defp traverse(ast, captures), do: {ast, captures}

  defp target({:., _, [module, fun]}) when is_atom(fun), do: target(module_key(module), fun)
  defp target(fun) when is_atom(fun), do: target(nil, fun)
  defp target(_call), do: nil

  # `module_key/1` returns `:error` for a dynamic module, which no key matches.
  defp target(module, fun) do
    case {@spawns[{module, fun}], @live_view_spawns[{module, fun}]} do
      {nil, nil} -> nil
      {nil, index} -> {name(module, fun), index, [:socket]}
      {index, _} -> {name(module, fun), index, []}
    end
  end

  defp module_key({:__aliases__, _, aliases}), do: aliases
  defp module_key(module) when is_atom(module), do: module
  defp module_key(_module), do: :error

  defp name(nil, fun), do: "#{fun}"
  defp name(module, fun) when is_atom(module), do: "#{inspect(module)}.#{fun}"
  defp name(aliases, fun), do: "#{Enum.join(aliases, ".")}.#{fun}"

  # `&Mod.fun/1`, `&fun/1` and `&module.fun/1` capture nothing.
  defp closure?({:fn, _, clauses}) when is_list(clauses), do: true
  defp closure?({:&, _, [{:/, _, [_fun, arity]}]}) when is_integer(arity), do: false
  defp closure?({:&, _, [_body]}), do: true
  defp closure?(_ast), do: false

  # Variables that the function only reads fields of, with the position of
  # their first use and the fields, in order. A variable that the function
  # binds, in a parameter or a pattern, appears whole there and is left out.
  defp field_only_captures(fun) do
    {_, uses} = Macro.prewalk(fun, %{}, &collect_use/2)

    for {name, %{whole?: false} = use} <- uses, do: {name, use.meta, Enum.reverse(use.fields)}
  end

  defp collect_use({:@, _, _}, uses), do: {nil, uses}

  defp collect_use({{:., _, [{name, meta, context}, field]}, call_meta, []} = ast, uses)
       when is_atom(name) and is_atom(context) and is_atom(field) do
    if call_meta[:no_parens] && variable?(name) do
      {nil, add_use(uses, name, meta, {:field, field})}
    else
      {ast, uses}
    end
  end

  defp collect_use({name, meta, context} = ast, uses) when is_atom(name) and is_atom(context) do
    if variable?(name), do: {ast, add_use(uses, name, meta, :whole)}, else: {ast, uses}
  end

  defp collect_use(ast, uses), do: {ast, uses}

  defp add_use(uses, name, meta, use) do
    current = Map.get(uses, name, %{meta: meta, fields: [], whole?: false})

    current =
      case use do
        :whole ->
          %{current | whole?: true}

        {:field, field} ->
          if field in current.fields,
            do: current,
            else: %{current | fields: [field | current.fields]}
      end

    Map.put(uses, name, current)
  end

  defp variable?(name), do: not String.starts_with?(Atom.to_string(name), "_")

  defp issue_for(issue_meta, {call, name, meta, fields}) do
    reads = fields |> Enum.map(&"`#{name}.#{&1}`") |> to_sentence()

    what =
      if length(fields) == 1, do: "the field into a variable", else: "the fields into variables"

    format_issue(
      issue_meta,
      message:
        "The function given to `#{call}` captures `#{name}` only to read #{reads}, " <>
          "so all of `#{name}` is copied to the process that runs it. " <>
          "Read #{what} before the function.",
      trigger: "#{name}",
      line_no: meta[:line],
      column: meta[:column]
    )
  end

  defp to_sentence([item]), do: item

  defp to_sentence(items) do
    {init, [last]} = Enum.split(items, -1)
    Enum.join(init, ", ") <> " and " <> last
  end
end
