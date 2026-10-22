defmodule Smell.Check.Warning.NamespaceTrespassingTest do
  use Credo.Test.Case

  @described_check Smell.Check.Warning.NamespaceTrespassing

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    lockfile = Path.join(tmp_dir, "mix.lock")

    File.write!(lockfile, """
    %{
      "jason": {:hex, :jason, "1.4.4", "", [:mix], [], "hexpm", ""},
      "plug": {:hex, :plug, "1.16.1", "", [:mix], [], "hexpm", ""},
    }
    """)

    %{params: [lockfile: lockfile]}
  end

  describe "reports" do
    test "a module inside a dependency's namespace", %{params: params} do
      """
      defmodule Plug.Auth do
      end
      """
      |> to_source_file()
      |> run_check(@described_check, params)
      |> assert_issue(fn issue ->
        assert issue.trigger == "Plug.Auth"
        assert issue.line_no == 1
        assert issue.column == 11
        assert issue.message =~ "the `:plug` dependency"
      end)
    end

    test "a module inside an Elixir namespace", %{params: params} do
      """
      defmodule Logger.Backends.Custom do
      end
      """
      |> to_source_file()
      |> run_check(@described_check, params)
      |> assert_issue(fn issue ->
        assert issue.trigger == "Logger.Backends.Custom"
        assert issue.message =~ "belongs to Elixir"
      end)
    end

    test "Mix modules that are not Mix tasks", %{params: params} do
      """
      defmodule Mix.MyLib do
      end
      """
      |> to_source_file()
      |> run_check(@described_check, params)
      |> assert_issue()
    end

    test "modules defined inside top-level conditionals", %{params: params} do
      """
      if Code.ensure_loaded?(Jason) do
        defmodule Jason.MyLibEncoder do
        end
      end
      """
      |> to_source_file()
      |> run_check(@described_check, params)
      |> assert_issue(fn issue -> assert issue.line_no == 2 end)
    end

    test "every offending module in a file", %{params: params} do
      """
      defmodule Plug.Auth do
      end

      defmodule MyLib do
      end

      defmodule Elixir.Jason.Extra do
      end
      """
      |> to_source_file()
      |> run_check(@described_check, params)
      |> assert_issues(fn issues ->
        assert issues |> Enum.map(& &1.trigger) |> Enum.sort() == [
                 "Elixir.Jason.Extra",
                 "Plug.Auth"
               ]

        assert Enum.any?(issues, &(&1.message =~ "`Jason.Extra` is defined"))
      end)
    end

    test "test helpers shipped under lib/", %{params: params} do
      """
      defmodule Plug.MyLibTest.Helpers do
      end
      """
      |> to_source_file("lib/my_lib/test/helpers.ex")
      |> run_check(@described_check, params)
      |> assert_issue()
    end

    test "namespaces next to an allowed one", %{params: params} do
      """
      defmodule Plug.Other do
      end
      """
      |> to_source_file()
      |> run_check(@described_check, [allowed_namespaces: [Plug.Auth]] ++ params)
      |> assert_issue()
    end
  end

  describe "does not report" do
    test "modules inside the project's own namespace", %{params: params} do
      """
      defmodule PlugAuth do
        defmodule Plug do
        end
      end

      defmodule PlugAuth.Session do
      end
      """
      |> to_source_file()
      |> run_check(@described_check, params)
      |> refute_issues()
    end

    test "custom Mix tasks", %{params: params} do
      """
      defmodule Mix.Tasks.MyLib.Setup do
        use Mix.Task
      end
      """
      |> to_source_file()
      |> run_check(@described_check, params)
      |> refute_issues()
    end

    test "protocol implementations", %{params: params} do
      """
      defimpl Jason.Encoder, for: MyLib.User do
        def encode(user, opts), do: Jason.Encode.map(Map.from_struct(user), opts)
      end
      """
      |> to_source_file()
      |> run_check(@described_check, params)
      |> refute_issues()
    end

    test "namespaces listed in allowed_namespaces", %{params: params} do
      """
      defmodule Plug.Auth.Session do
      end

      defmodule Mix.MyLib do
      end
      """
      |> to_source_file()
      |> run_check(@described_check, [allowed_namespaces: [Plug.Auth, "Mix.MyLib"]] ++ params)
      |> refute_issues()
    end

    test "test files, unless exclude_test_files is false", %{params: params} do
      source = """
      defmodule Mix.MyLibTest do
      end
      """

      for filename <- ["test/mix/my_lib_test.exs", "apps/my_lib/test/support/stub.ex"] do
        source
        |> to_source_file(filename)
        |> run_check(@described_check, params)
        |> refute_issues()
      end

      source
      |> to_source_file("test/mix/my_lib_test.exs")
      |> run_check(@described_check, [exclude_test_files: false] ++ params)
      |> assert_issue()
    end

    test "dependency namespaces when there is no lockfile", %{tmp_dir: tmp_dir} do
      """
      defmodule Plug.Auth do
      end
      """
      |> to_source_file()
      |> run_check(@described_check, lockfile: Path.join(tmp_dir, "missing.lock"))
      |> refute_issues()
    end

    test "module names built at compile time", %{params: params} do
      """
      defmodule unquote(name) do
      end

      defmodule __MODULE__.Plug do
      end

      defmodule :erlang_style do
      end
      """
      |> to_source_file()
      |> run_check(@described_check, params)
      |> refute_issues()
    end
  end
end
