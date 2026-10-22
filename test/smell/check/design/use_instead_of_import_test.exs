defmodule Smell.Check.Design.UseInsteadOfImportTest do
  use Credo.Test.Case

  @described_check Smell.Check.Design.UseInsteadOfImport

  defp run(source, filename \\ "lib/library.ex", params \\ []) do
    source
    |> to_source_file(filename)
    |> run_check(@described_check, params)
  end

  describe "reports" do
    test "a __using__ that only imports" do
      """
      defmodule Library do
        defmacro __using__(_opts) do
          quote do
            import Library
            import ModuleA
          end
        end

        def from_lib, do: "From Library"
      end
      """
      |> run()
      |> assert_issue(fn issue ->
        assert issue.trigger == "__using__"
        assert issue.line_no == 2
        assert issue.column == 12

        assert issue.message =~
                 "`__using__/1` only injects `import Library`, `import ModuleA`."
      end)
    end

    test "aliases and requires" do
      """
      defmodule MyApp.Repo do
        defmacro __using__(_) do
          quote do
            alias MyApp.Repo
            require Logger
            import Ecto.Query, only: [from: 2]
          end
        end
      end
      """
      |> run()
      |> assert_issue(fn issue ->
        assert issue.message =~ "`alias MyApp.Repo`, `require Logger`, `import Ecto.Query`."
      end)
    end

    test "a single directive, in keyword syntax" do
      """
      defmodule Library do
        defmacro __using__(_), do: quote(do: import(Library))
      end
      """
      |> run()
      |> assert_issue()
    end

    test "code that runs before the quote" do
      """
      defmodule Library do
        defmacro __using__(opts) do
          only = Keyword.get(opts, :only, [])

          quote location: :keep do
            import Library, only: unquote(only)
          end
        end
      end
      """
      |> run()
      |> assert_issue()
    end

    test "a guarded clause and a dynamic import target" do
      """
      defmodule Library do
        defmacro __using__(module) when is_atom(module) do
          quote do
            import unquote(module)
          end
        end
      end
      """
      |> run()
      |> assert_issue(fn issue -> assert issue.message =~ "`import unquote(module)`" end)
    end

    test "once for a __using__ with several clauses" do
      """
      defmodule Library do
        defmacro __using__([]), do: quote(do: import(Library))

        defmacro __using__(_opts) do
          quote do
            import Library
            alias Library.Helpers
          end
        end
      end
      """
      |> run()
      |> assert_issue(fn issue ->
        assert issue.line_no == 2
        assert issue.message =~ "only injects `import Library`, `alias Library.Helpers`."
      end)
    end

    test "a long list of directives, shortened" do
      """
      defmodule MyApp.Shared do
        defmacro __using__(_opts) do
          quote do
            alias MyApp.{Accounts, Billing, Repo}
            alias MyApp.Mailer
            import Ecto.Query
            import MyApp.Helpers
            require Logger
          end
        end
      end
      """
      |> run()
      |> assert_issue(fn issue ->
        assert issue.message =~
                 "`alias MyApp.{...}`, `alias MyApp.Mailer`, `import Ecto.Query` and 2 more."
      end)
    end

    test "nested modules, each on its own" do
      """
      defmodule Library do
        defmodule Query do
          defmacro __using__(_), do: quote(do: import(Library.Query))
        end

        defmodule Schema do
          defmacro __using__(_), do: quote(do: import(Library.Schema))
        end
      end
      """
      |> run()
      |> assert_issues(fn issues -> assert length(issues) == 2 end)
    end

    test "a module with a dynamic name" do
      """
      for name <- [A, B] do
        defmodule Module.concat(Library, name) do
          defmacro __using__(_), do: quote(do: import(unquote(__MODULE__)))
        end
      end
      """
      |> run()
      |> assert_issue()
    end

    test "test files when :exclude_test_files is false" do
      """
      defmodule MyApp.Factory do
        defmacro __using__(_), do: quote(do: import(MyApp.Factory))
      end
      """
      |> run("test/support/factory.ex", exclude_test_files: false)
      |> assert_issue()
    end

    test "test helpers that ship with the library" do
      """
      defmodule Plug.Test do
        defmacro __using__(_) do
          quote do
            import Plug.Test
            import Plug.Conn
          end
        end
      end
      """
      |> run("lib/plug/test.ex")
      |> assert_issue()
    end
  end

  describe "does not report" do
    test "a __using__ that injects more than directives" do
      for injected <- [
            "def from_lib, do: :ok",
            "@behaviour Library",
            "use GenServer",
            "@before_compile Library",
            "Module.register_attribute(__MODULE__, :fields, accumulate: true)",
            "unquote(extra)"
          ] do
        """
        defmodule Library do
          defmacro __using__(extra) do
            quote do
              import Library
              #{injected}
            end
          end
        end
        """
        |> run()
        |> refute_issues()
      end
    end

    test "a directive inside a conditional" do
      """
      defmodule Library do
        defmacro __using__(opts) do
          quote do
            if unquote(opts[:query]), do: import(Ecto.Query)
          end
        end
      end
      """
      |> run()
      |> refute_issues()
    end

    test "a clause that injects more than directives" do
      """
      defmodule Library do
        defmacro __using__(:query), do: quote(do: import(Ecto.Query))

        defmacro __using__(_opts) do
          quote do
            import Library
            def from_lib, do: :ok
          end
        end
      end
      """
      |> run()
      |> refute_issues()
    end

    test "a __using__ that does not end in a quote" do
      """
      defmodule MyAppWeb do
        def controller do
          quote do
            import Plug.Conn
          end
        end

        defmacro __using__(which) when is_atom(which) do
          apply(__MODULE__, which, [])
        end
      end
      """
      |> run()
      |> refute_issues()
    end

    test "an empty quote" do
      """
      defmodule Library do
        defmacro __using__(_), do: quote(do: nil)
        defmacro __using__(_opts) do
          quote do
          end
        end
      end
      """
      |> run()
      |> refute_issues()
    end

    test "a deprecated __using__" do
      for code <- [
            """
            @doc false
            @deprecated "Use import Library instead"
            defmacro __using__(_), do: quote(do: import(Library))
            """,
            """
            defmacro __using__(_) do
              IO.warn("use Library is deprecated, import Library instead", Macro.Env.stacktrace(__CALLER__))
              quote do
                import Library
              end
            end
            """
          ] do
        """
        defmodule Library do
          #{code}
        end
        """
        |> run()
        |> refute_issues()
      end
    end

    test "a deprecation of an earlier function" do
      """
      defmodule Library do
        @deprecated "Use bar/0"
        def foo, do: :ok

        defmacro __using__(_), do: quote(do: import(Library))
      end
      """
      |> run()
      |> assert_issue()
    end

    test "functions, variables and other macros with the same names" do
      """
      defmodule Library do
        def __using__(_), do: quote(do: import(Library))

        defmacro using(_), do: quote(do: import(Library))

        defmacro other(quote) do
          __using__ = quote
          import Library
          __using__
        end
      end
      """
      |> run()
      |> refute_issues()
    end

    test "ExUnit case templates" do
      """
      defmodule MyApp.DataCase do
        use ExUnit.CaseTemplate

        using do
          quote do
            alias MyApp.Repo
            import Ecto.Query
          end
        end
      end
      """
      |> run("lib/my_app/data_case.ex")
      |> refute_issues()
    end

    test "test files" do
      """
      defmodule MyApp.Factory do
        defmacro __using__(_), do: quote(do: import(MyApp.Factory))
      end
      """
      |> run("test/support/factory.ex")
      |> refute_issues()
    end
  end
end
