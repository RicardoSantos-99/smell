defmodule Smell.Check.Design.AppConfigInLibrary do
  use Credo.Check,
    base_priority: :normal,
    tags: [:anti_pattern],
    param_defaults: [library: :auto, allowed_keys: [], exclude_test_files: true],
    docs_uri:
      "https://hexdocs.pm/elixir/design-anti-patterns.html#using-application-configuration-for-libraries",
    explanations: [
      check: """
      Libraries should not be configured through the application environment.

      This is the "Using application configuration for libraries" anti-pattern
      from the official Elixir documentation. The application environment is
      global: there is a single value for each key, so two applications that
      depend on the same library cannot configure it in different ways.

          defmodule DashSplitter do
            def split(string) do
              parts = Application.fetch_env!(:dash_splitter, :parts)
              String.split(string, "-", parts: parts)
            end
          end

      Accept the value as an option instead, with a default:

          defmodule DashSplitter do
            def split(string, opts \\\\ []) do
              parts = Keyword.get(opts, :parts, 2)
              String.split(string, "-", parts: parts)
            end
          end

      If the library starts processes, provide a child spec that takes
      options, so each application starts it in its own supervision tree.
      Settings needed at compile time can be options to `use`, as in
      `use Ecto.Repo, adapter: Ecto.Adapters.Postgres`. Mix tasks can read
      per-project settings with `Mix.Project.config/0` or accept command-line
      options.

      Inside a library, a read of the library's own application environment
      is reported: `Application.get_env/3`, `fetch_env/2`, `fetch_env!/2`,
      `get_all_env/1`, `compile_env/3`, `compile_env!/2`, and the Erlang
      `:application.get_env/2,3` and `get_all_env/1`. A project is a library
      when its `mix.exs` has a `:package` and no `:releases`.

      Not reported, following the exceptions in the Elixir documentation:

        * keys that swap a component for another one with the same behaviour,
          such as `:adapter`, `:json_library` or `:http_client` (names equal to
          or ending in `adapter`, `client`, `codec`, `impl`, `library`,
          `module` or `parser`)
        * the `:otp_app` pattern, where the library reads the environment of
          the application that uses it instead of its own
        * keys listed in `:allowed_keys`, for example the settings of code
          generated from data files

      Also not reported: reads that only decide whether to print a warning
      with `IO.warn` or `IO.puts(:stderr, ...)`, usually about deprecated
      configuration; reads of other applications' environments (such as
      `:logger`); and files where `Application` is an alias to another module.
      """,
      params: [
        library:
          "`:auto` checks the project when its `mix.exs` has a `:package` and no `:releases`, " <>
            "`true` always checks it, `false` never does. The app name always comes from `mix.exs`.",
        allowed_keys:
          "Keys the library may read, as atoms or regexes, e.g. `[:debug, ~r/_adapter$/]`. " <>
            "For a key path such as `[MyLib.Repo, :timeout]`, the last key is matched.",
        exclude_test_files: "Skip files under `test/`."
      ]
    ]

  alias Smell.Check.Helpers

  # Keys that name a component, e.g. :adapter, :json_library, :http_client.
  @component_keys ~w(adapter client codec impl library module parser)

  @no_project %{app: nil, library?: false}

  @doc false
  @impl true
  def run(%SourceFile{} = source_file, params) do
    if Params.get(params, :exclude_test_files, __MODULE__) and
         Helpers.test_file?(source_file.filename) do
      []
    else
      case own_app(source_file.filename, Params.get(params, :library, __MODULE__)) do
        nil -> []
        app -> check_reads(source_file, app, params)
      end
    end
  end

  defp own_app(_filename, false), do: nil

  defp own_app(filename, library) do
    %{app: app, library?: library?} = project(filename)
    if library == true or library?, do: app
  end

  defp check_reads(source_file, app, params) do
    issue_meta = IssueMeta.for(source_file, params)
    allowed = Params.get(params, :allowed_keys, __MODULE__)

    state = %{
      app: app,
      module: nil,
      scope: :body,
      unquote_scope: nil,
      attributes: %{},
      aliased?: Credo.Code.prewalk(source_file, &find_application_alias/2, false)
    }

    source_file
    |> SourceFile.ast()
    |> walk(state, [])
    |> Enum.reverse()
    |> Enum.reject(&allowed_key?(&1.key, allowed))
    |> Enum.map(&issue_for(issue_meta, app, &1))
  end

  ## Traversal
  #
  # `scope` says when the code runs: `:body` (module body, compile time),
  # `:def`, `:macro` (defmacro outside quote, compile time of the caller) or
  # `:quote`. Inside a quote, `unquote_scope` is the scope that `unquote` goes
  # back to.

  defp walk({:defmodule, _, [{:__aliases__, _, parts}, [do: body]]}, state, acc) do
    module = module_name(state.module, parts)
    state = %{state | module: module, scope: :body, attributes: module_attributes(body)}
    walk(body, state, acc)
  end

  defp walk({kind, _, args}, state, acc) when kind in [:def, :defp] and is_list(args),
    do: walk(args, %{state | scope: :def}, acc)

  defp walk({kind, _, args}, state, acc) when kind in [:defmacro, :defmacrop] and is_list(args),
    do: walk(args, %{state | scope: :macro}, acc)

  defp walk({:quote, _, args}, state, acc) when is_list(args),
    do: walk(args, %{state | scope: :quote, unquote_scope: state.scope}, acc)

  defp walk({form, _, args}, %{unquote_scope: scope} = state, acc)
       when form in [:unquote, :unquote_splicing] and is_list(args) and not is_nil(scope),
       do: walk(args, %{state | scope: scope, unquote_scope: nil}, acc)

  # Reads that only decide whether to print a warning, usually about deprecated
  # configuration, do not configure the library:
  #
  #     if Application.get_env(:my_lib, :old_key), do: IO.warn("...")
  #
  defp walk({form, _, [condition, branches]}, state, acc)
       when form in [:if, :unless] and is_list(branches) do
    if Keyword.keyword?(branches) and Enum.all?(Keyword.values(branches), &warning_only?/1),
      do: walk(branches, state, acc),
      else: walk(branches, state, walk(condition, state, acc))
  end

  defp walk({:case, _, [subject, [do: clauses]]}, state, acc) when is_list(clauses) do
    bodies = for {:->, _, [_patterns, body]} <- clauses, do: body

    if length(bodies) == length(clauses) and Enum.all?(bodies, &warning_only?/1),
      do: walk(clauses, state, acc),
      else: walk(clauses, state, walk(subject, state, acc))
  end

  # `:my_lib |> Application.get_env(:key)`
  defp walk({:|>, _, [left, {{:., _, [module, _]} = dot, _, args}]}, state, acc)
       when is_list(args) do
    acc = add_read(dot, [left | args], state, acc)
    walk([left, module | args], state, acc)
  end

  defp walk({{:., _, [_, _]} = dot, _, args} = call, state, acc) when is_list(args) do
    acc = add_read(dot, args, state, acc)
    walk_children(call, state, acc)
  end

  defp walk(ast, state, acc), do: walk_children(ast, state, acc)

  defp walk_children({form, _meta, args}, state, acc),
    do: walk(args, state, walk(form, state, acc))

  defp walk_children({left, right}, state, acc), do: walk(right, state, walk(left, state, acc))

  defp walk_children(list, state, acc) when is_list(list),
    do: Enum.reduce(list, acc, &walk(&1, state, &2))

  defp walk_children(_ast, _state, acc), do: acc

  defp warning_only?(body), do: body |> statements() |> Enum.all?(&warning?/1)

  defp warning?({{:., _, [{:__aliases__, _, [:IO]}, :warn]}, _, _args}), do: true
  defp warning?({{:., _, [{:__aliases__, _, [:IO]}, :puts]}, _, [:stderr, _]}), do: true
  defp warning?(literal), do: is_atom(literal)

  defp module_name(parent, parts) do
    name = Enum.map_join(parts, ".", &if(is_atom(&1), do: Atom.to_string(&1), else: "_"))

    cond do
      String.starts_with?(name, "Elixir.") -> String.replace_prefix(name, "Elixir.", "")
      parent -> parent <> "." <> name
      true -> name
    end
  end

  # `@app :my_lib`, to resolve `Application.get_env(@app, :key)`.
  defp module_attributes(body) do
    for {:@, _, [{name, _, [value]}]} <- statements(body),
        is_atom(name) and is_atom(value),
        into: %{},
        do: {name, value}
  end

  defp statements({:__block__, _, statements}), do: statements
  defp statements(statement), do: [statement]

  ## Reads of the application environment

  defp add_read({:., dot_meta, [module, fun]}, args, state, acc) do
    with {written, meta} <- application_module(module, fun, dot_meta, state),
         {app, key} <- read_args(fun, args),
         true <- own_app?(app, state) do
      read = %{
        trigger: "#{written}.#{fun}",
        line: meta[:line],
        column: meta[:column],
        fun: fun,
        key: key,
        scope: state.scope,
        module: state.module
      }

      [read | acc]
    else
      _ -> acc
    end
  end

  defp application_module({:__aliases__, meta, [:Application]}, fun, _dot_meta, state) do
    if not state.aliased? and elixir_read?(fun), do: {"Application", meta}
  end

  defp application_module({:__aliases__, meta, [:"Elixir", :Application]}, fun, _dot_meta, _state) do
    if elixir_read?(fun), do: {"Elixir.Application", meta}
  end

  defp application_module(:application, fun, dot_meta, _state)
       when fun in [:get_env, :get_all_env] do
    column = dot_meta[:column] && dot_meta[:column] - String.length(":application")
    {":application", line: dot_meta[:line], column: column}
  end

  defp application_module(_module, _fun, _dot_meta, _state), do: nil

  defp elixir_read?(fun),
    do: fun in [:get_env, :fetch_env, :fetch_env!, :get_all_env, :compile_env, :compile_env!]

  # Returns `{app, key}`, with a `nil` key for `get_all_env/1`. Elixir 1.14 added
  # `compile_env/4` and `compile_env!/3`, which take the caller's `__ENV__` first.
  defp read_args(:get_all_env, [app]), do: {app, nil}
  defp read_args(:get_env, [app, key | default]) when length(default) <= 1, do: {app, key}
  defp read_args(fun, [app, key]) when fun in [:fetch_env, :fetch_env!], do: {app, key}
  defp read_args(:compile_env, [app, key | default]) when length(default) <= 1, do: {app, key}
  defp read_args(:compile_env, [_env, app, key, _default]), do: {app, key}
  defp read_args(:compile_env!, [app, key]), do: {app, key}
  defp read_args(:compile_env!, [_env, app, key]), do: {app, key}
  defp read_args(_fun, _args), do: nil

  defp own_app?(app, %{app: app}), do: true

  defp own_app?({:@, _, [{name, _, context}]}, state) when is_atom(context),
    do: Map.get(state.attributes, name) == state.app

  defp own_app?(_app, _state), do: false

  # `alias MyLib.Application`, `alias Foo, as: Application` and
  # `alias MyLib.{Application, Repo}` make `Application` another module.
  defp find_application_alias(ast, true), do: {ast, true}

  defp find_application_alias({:alias, _, [target | opts]} = ast, false) do
    as = opts |> List.first([]) |> keyword_get(:as)
    {ast, if(as, do: alias_name(as) == [:Application], else: aliases_application?(target))}
  end

  defp find_application_alias(
         {:defmodule, _, [{:__aliases__, _, [:Application]}, _]} = ast,
         false
       ),
       do: {ast, true}

  defp find_application_alias(ast, false), do: {ast, false}

  defp aliases_application?({{:., _, [_base, :{}]}, _, children}),
    do: Enum.any?(children, &(alias_name(&1) |> List.last() == :Application))

  defp aliases_application?(target) do
    case alias_name(target) do
      [:"Elixir", :Application] -> false
      [_ | _] = parts -> length(parts) > 1 and List.last(parts) == :Application
      _ -> false
    end
  end

  defp alias_name({:__aliases__, _, parts}), do: parts
  defp alias_name(_ast), do: nil

  defp keyword_get(opts, key) when is_list(opts) do
    if Keyword.keyword?(opts), do: Keyword.get(opts, key)
  end

  defp keyword_get(_opts, _key), do: nil

  ## Allowed keys

  defp allowed_key?(key, allowed) do
    case key_name(key) do
      nil -> false
      name -> component?(name) or Enum.any?(allowed, &allowed?(&1, name))
    end
  end

  # For a key path such as `[MyLib.Repo, :timeout]`, the last key.
  defp key_name(path) when is_list(path) and path != [], do: path |> List.last() |> key_name()

  defp key_name({:__aliases__, _, parts}),
    do: if(Enum.all?(parts, &is_atom/1), do: inspect(Module.concat(parts)))

  defp key_name(key) when is_atom(key) and not is_nil(key), do: atom_name(key)
  defp key_name(_key), do: nil

  defp component?(name),
    do: Enum.any?(@component_keys, &(name == &1 or String.ends_with?(name, "_" <> &1)))

  defp allowed?(%Regex{} = regex, name), do: Regex.match?(regex, name)
  defp allowed?(key, name) when is_atom(key), do: atom_name(key) == name
  defp allowed?(key, name) when is_binary(key), do: key == name
  defp allowed?(_key, _name), do: false

  defp atom_name(atom), do: atom |> Atom.to_string() |> String.replace_prefix("Elixir.", "")

  ## Issues

  defp issue_for(issue_meta, app, read) do
    format_issue(
      issue_meta,
      message: message(kind(read), inspect(app), describe_key(read.key)),
      trigger: read.trigger,
      line_no: read.line,
      column: read.column
    )
  end

  defp kind(%{module: "Mix.Tasks." <> _}), do: :mix_task
  defp kind(%{fun: fun}) when fun in [:compile_env, :compile_env!], do: :compile_time
  defp kind(%{scope: scope}) when scope in [:body, :macro], do: :compile_time
  defp kind(_read), do: :runtime

  defp message(:runtime, app, key) do
    "Library `#{app}` reads #{key} from its application environment, which is global. " <>
      "Accept it as an option instead (a function argument, a child spec option or `:otp_app`)."
  end

  defp message(:compile_time, app, key) do
    "Library `#{app}` reads #{key} from its application environment at compile time, which is global. " <>
      "Accept it as an option instead, at runtime or in `use`."
  end

  defp message(:mix_task, app, key) do
    "Mix task reads #{key} from the `#{app}` application environment. " <>
      "Read per-project settings with `Mix.Project.config/0` or accept a command-line option instead."
  end

  defp describe_key(nil), do: "all keys"
  defp describe_key(key) when is_atom(key), do: "`#{inspect(key)}`"
  defp describe_key(key), do: "`#{Macro.to_string(key)}`"

  ## mix.exs

  defp project(filename) do
    case filename |> Path.expand() |> Path.dirname() |> find_mix_file() do
      nil -> @no_project
      path -> Helpers.cached_read(__MODULE__, path, @no_project, &read_project/1)
    end
  end

  # The nearest mix.exs, so each app of an umbrella uses its own.
  defp find_mix_file(dir) do
    path = Path.join(dir, "mix.exs")

    cond do
      File.regular?(path) -> path
      Path.dirname(dir) == dir -> nil
      true -> find_mix_file(Path.dirname(dir))
    end
  end

  # mix.exs is parsed, not evaluated: the first keyword list with an `:app` is
  # the project config, and `app: @app` is resolved from the module attributes.
  defp read_project(path) do
    with {:ok, contents} <- File.read(path),
         {:ok, ast} <- Code.string_to_quoted(contents, emit_warnings: false),
         {_, {attributes, [_ | _] = project}} <-
           Macro.prewalk(ast, {%{}, nil}, &collect_project/2) do
      app =
        case Keyword.get(project, :app) do
          {:@, _, [{name, _, _}]} -> Map.get(attributes, name)
          app when is_atom(app) -> app
          _ -> nil
        end

      library? = Keyword.has_key?(project, :package) and not Keyword.has_key?(project, :releases)
      %{app: app, library?: library?}
    else
      _ -> @no_project
    end
  end

  defp collect_project({:@, _, [{name, _, [value]}]} = ast, {attributes, project})
       when is_atom(name) and is_atom(value),
       do: {ast, {Map.put(attributes, name, value), project}}

  defp collect_project([_ | _] = list, {attributes, nil} = acc) do
    if Keyword.keyword?(list) and Keyword.has_key?(list, :app),
      do: {list, {attributes, list}},
      else: {list, acc}
  end

  defp collect_project(ast, acc), do: {ast, acc}
end
