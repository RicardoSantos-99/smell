defmodule Smell.Check.Warning.NamespaceTrespassing do
  use Credo.Check,
    base_priority: :high,
    tags: [:anti_pattern],
    param_defaults: [allowed_namespaces: [], lockfile: "mix.lock", exclude_test_files: true],
    docs_uri: "https://hexdocs.pm/elixir/code-anti-patterns.html#namespace-trespassing",
    explanations: [
      check: """
      Do not define modules inside a namespace that belongs to someone else.

      This is the "Namespace trespassing" anti-pattern from the official Elixir
      documentation. The Erlang VM can only load one module with a given name,
      so if a package defines `Plug.Auth` and Plug later adds its own
      `Plug.Auth`, the two can no longer be used together.

          # A package called :plug_auth
          defmodule Plug.Auth do
            # ...
          end

      Use your own name as the prefix of every module instead:

          defmodule PlugAuth do
            # ...
          end

      A top-level module is reported when the first segment of its name is a
      namespace owned by Elixir (such as `Mix`, `Logger` or `String`) or by one
      of the project's dependencies, as listed in `mix.lock` (`:plug` owns
      `Plug`, `:phoenix` owns `Phoenix`).

      Not reported, following the exceptions in the Elixir documentation:

        * custom Mix tasks under `Mix.Tasks`, a namespace Elixir opens on purpose
        * protocol implementations defined with `defimpl`
        * namespaces listed in `:allowed_namespaces`, for example when you
          maintain both packages

      Files under `test/` are skipped by default: test code is not shipped, and
      test modules often mirror or stub the modules they test.

      Dependencies whose modules do not start with their camelized app name
      (such as `:mime`, which defines `MIME`) are not detected.
      """,
      params: [
        allowed_namespaces:
          "Namespaces this project may define modules in, e.g. `[Phoenix.LiveView]` or `[\"Phoenix\"]`.",
        lockfile: "Path of the lockfile to read dependencies from, relative to where Credo runs.",
        exclude_test_files: "Skip files under `test/`."
      ]
    ]

  alias Smell.Check.Helpers

  @elixir_apps [:elixir, :eex, :ex_unit, :iex, :logger, :mix]

  # Root namespaces of every module shipped with Elixir, e.g. "Mix", "Logger", "String".
  @elixir_namespaces @elixir_apps
                     |> Enum.flat_map(fn app ->
                       Application.load(app)
                       Application.spec(app, :modules) || []
                     end)
                     |> Enum.map(&Atom.to_string/1)
                     |> Enum.filter(&String.starts_with?(&1, "Elixir."))
                     |> Enum.map(fn "Elixir." <> name -> name |> String.split(".") |> hd() end)
                     |> MapSet.new()

  @doc false
  @impl true
  def run(%SourceFile{} = source_file, params) do
    if Params.get(params, :exclude_test_files, __MODULE__) and
         Helpers.test_file?(source_file.filename) do
      []
    else
      check_modules(source_file, params)
    end
  end

  defp check_modules(source_file, params) do
    issue_meta = IssueMeta.for(source_file, params)
    allowed = params |> Params.get(:allowed_namespaces, __MODULE__) |> Enum.map(&namespace_name/1)
    dependencies = params |> Params.get(:lockfile, __MODULE__) |> dependency_namespaces()

    source_file
    |> Credo.Code.prewalk(&collect_top_level_modules/2)
    |> Enum.reverse()
    |> Enum.flat_map(fn {name, written_as, meta} ->
      case owner(name, allowed, dependencies) do
        nil -> []
        owner -> [issue_for(issue_meta, name, written_as, meta, owner)]
      end
    end)
  end

  # Records modules defined at the top level of a file, including inside
  # top-level conditionals such as `if Code.ensure_loaded?(Jason) do ... end`,
  # and does not descend into them: nested modules are named after their parent.
  defp collect_top_level_modules({:defmodule, _, [{:__aliases__, meta, parts}, _]}, acc) do
    if Enum.all?(parts, &is_atom/1) do
      name = parts |> drop_elixir_prefix() |> Enum.map_join(".", &Atom.to_string/1)
      written_as = Enum.map_join(parts, ".", &Atom.to_string/1)
      {nil, [{name, written_as, meta} | acc]}
    else
      {nil, acc}
    end
  end

  defp collect_top_level_modules({:defmodule, _meta, _args}, acc), do: {nil, acc}
  defp collect_top_level_modules(ast, acc), do: {ast, acc}

  defp drop_elixir_prefix([:"Elixir" | parts]), do: parts
  defp drop_elixir_prefix(parts), do: parts

  defp owner("Mix.Tasks." <> _, _allowed, _dependencies), do: nil

  defp owner(name, allowed, dependencies) do
    root = name |> String.split(".") |> hd()

    cond do
      Enum.any?(allowed, &inside?(name, &1)) -> nil
      Map.has_key?(dependencies, root) -> {root, {:dependency, Map.fetch!(dependencies, root)}}
      MapSet.member?(@elixir_namespaces, root) -> {root, :elixir}
      true -> nil
    end
  end

  defp inside?(name, namespace),
    do: name == namespace or String.starts_with?(name, namespace <> ".")

  defp namespace_name(namespace) when is_atom(namespace), do: inspect(namespace)

  defp namespace_name(namespace) when is_binary(namespace),
    do: String.trim_leading(namespace, "Elixir.")

  defp dependency_namespaces(lockfile),
    do: Helpers.cached_read(__MODULE__, lockfile, %{}, &read_lockfile/1)

  defp read_lockfile(path) do
    with {:ok, contents} <- File.read(path),
         {:ok, {:%{}, _, entries}} <- Code.string_to_quoted(contents, emit_warnings: false) do
      for {app, _} <- entries, is_atom(app), into: %{} do
        {app |> Atom.to_string() |> Macro.camelize(), app}
      end
    else
      _ -> %{}
    end
  end

  defp issue_for(issue_meta, name, written_as, meta, {root, owner}) do
    format_issue(
      issue_meta,
      message:
        "`#{name}` is defined inside the `#{root}` namespace, which belongs to #{describe(owner)}. " <>
          "Use your own namespace, or list it in :allowed_namespaces if you maintain both.",
      trigger: written_as,
      line_no: meta[:line],
      column: meta[:column]
    )
  end

  defp describe(:elixir), do: "Elixir"
  defp describe({:dependency, app}), do: "the `#{inspect(app)}` dependency"
end
