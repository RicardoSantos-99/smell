defmodule Smell.Check.Design.UnsupervisedProcess do
  use Credo.Check,
    base_priority: :normal,
    tags: [:anti_pattern],
    param_defaults: [exclude_test_files: true],
    docs_uri: "https://hexdocs.pm/elixir/process-anti-patterns.html#unsupervised-processes",
    explanations: [
      check: """
      Start long-running processes under a supervisor, not from the callbacks
      of another process.

      This is the "Unsupervised processes" anti-pattern from the official
      Elixir documentation. Starting a process outside a supervision tree is
      not a problem in itself, but when many long-running processes are
      started that way, nothing controls the order in which they start and
      stop, how they restart, or how to inspect them. A common case is a
      server that starts one process per message:

          def handle_info(:accept, listen_socket) do
            {:ok, socket} = :gen_tcp.accept(listen_socket)
            {:ok, pid} = Connection.start_link(socket)
            :ok = :gen_tcp.controlling_process(socket, pid)
            send(self(), :accept)
            {:noreply, listen_socket}
          end

      Start those processes under a supervisor from your supervision tree
      instead:

          {:ok, pid} =
            DynamicSupervisor.start_child(MyApp.ConnectionSupervisor, {Connection, socket})

      A call is reported when it starts a process (`GenServer.start/3`,
      `GenServer.start_link/3`, `Agent.start/2`, `Agent.start_link/2`,
      `start_link` of `Supervisor`, `DynamicSupervisor`,
      `PartitionSupervisor`, `Registry` or `Task.Supervisor`, the Erlang
      `:gen_server`, `:gen_statem`, `:gen_event` and `:supervisor` starts,
      or `start_link` of any other module) inside a `handle_call/3`,
      `handle_cast/2`, `handle_info/2`, `handle_event/3`, `handle_event/4` or
      `handle_in/3` callback.

      Not reported:

        * starts in `start_link`, `start`, `child_spec`, `init/1`,
          `handle_continue/2` and other functions, which usually start one
          process per server, or a temporary one
        * `Task.start/1`, `Task.async/1`, `spawn/1` and similar, which
          usually start short-lived processes
        * files under `test/`, by default

      This check is opt-in: the Smell plugin does not enable it. Add it to
      the `checks` of your `.credo.exs`:

          checks: %{extra: [{Smell.Check.Design.UnsupervisedProcess, []}]}
      """,
      params: [
        exclude_test_files: "Skip files under `test/`."
      ]
    ]

  alias Smell.Check.Helpers

  # Callbacks that run once per message, with their arities.
  @callbacks [
    handle_call: [3],
    handle_cast: [2],
    handle_info: [2],
    handle_event: [3, 4],
    handle_in: [3]
  ]

  # Functions that start a process, for the modules that do not follow the
  # `start_link` convention or that also have `start`. `Task` starts
  # short-lived processes.
  @elixir_starts %{
    [:GenServer] => [:start, :start_link],
    [:Agent] => [:start, :start_link],
    [:Supervisor] => [:start_link],
    [:DynamicSupervisor] => [:start_link],
    [:PartitionSupervisor] => [:start_link],
    [:Registry] => [:start_link],
    [:Task, :Supervisor] => [:start_link],
    [:Task] => []
  }

  @erlang_starts %{
    gen_server: [:start, :start_link],
    gen_statem: [:start, :start_link],
    gen_event: [:start, :start_link],
    supervisor: [:start_link]
  }

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

  defp traverse({:def, _, [head, body]} = ast, issues, issue_meta) when is_list(body) do
    case callback(head) do
      nil ->
        {ast, issues}

      callback ->
        issues =
          body
          |> process_starts()
          |> Enum.reduce(issues, fn {name, meta}, issues ->
            [issue_for(issue_meta, name, meta, callback) | issues]
          end)

        {ast, issues}
    end
  end

  defp traverse(ast, issues, _issue_meta), do: {ast, issues}

  defp callback({:when, _, [head | _]}), do: callback(head)

  defp callback({name, _, args}) when is_atom(name) and is_list(args) do
    if length(args) in Keyword.get(@callbacks, name, []), do: "#{name}/#{length(args)}"
  end

  defp callback(_head), do: nil

  defp process_starts(body) do
    body
    |> Macro.prewalk([], fn ast, starts ->
      case process_start(ast) do
        nil -> {ast, starts}
        start -> {ast, [start | starts]}
      end
    end)
    |> elem(1)
  end

  # `Module.fun(...)`, also inside a pipe or a capture. Returns the name of
  # the call and the position of the module.
  defp process_start({{:., dot_meta, [module, fun]}, _meta, args})
       when is_atom(fun) and is_list(args) do
    if start?(module, fun), do: {"#{name(module)}.#{fun}", position(module, dot_meta)}
  end

  defp process_start(_ast), do: nil

  defp start?({:__aliases__, _, aliases}, fun) do
    case Map.fetch(@elixir_starts, aliases) do
      {:ok, funs} -> fun in funs
      :error -> fun == :start_link
    end
  end

  defp start?({:__MODULE__, _, context}, fun) when is_atom(context), do: fun == :start_link
  defp start?(module, fun) when is_atom(module), do: fun in Map.get(@erlang_starts, module, [])
  defp start?(_module, _fun), do: false

  defp name(module) when is_atom(module), do: inspect(module)
  defp name(module), do: Macro.to_string(module)

  # `__MODULE__.Worker` keeps the position of `__MODULE__`, and an Erlang
  # module has none, so its column comes from the dot.
  defp position({:__aliases__, _, [{:__MODULE__, meta, _} | _]}, _dot_meta), do: meta
  defp position({_, meta, _}, _dot_meta), do: meta

  defp position(module, dot_meta) do
    column = dot_meta[:column] && dot_meta[:column] - String.length(inspect(module))
    [line: dot_meta[:line], column: column]
  end

  defp issue_for(issue_meta, name, meta, callback) do
    format_issue(
      issue_meta,
      message:
        "`#{name}` starts a process in `#{callback}`, outside a supervision tree. " <>
          "Start it under a supervisor, for example with `DynamicSupervisor.start_child/2`.",
      trigger: name,
      line_no: meta[:line],
      column: meta[:column]
    )
  end
end
