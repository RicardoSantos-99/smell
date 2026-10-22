defmodule Smell.Check.Warning.NonAssertivePatternMatchingTest do
  use Credo.Test.Case

  @described_check Smell.Check.Warning.NonAssertivePatternMatching

  defp run(source, filename \\ "lib/example.ex", params \\ []) do
    source
    |> to_source_file(filename)
    |> run_check(@described_check, params)
  end

  defp in_function(clauses) do
    """
    defmodule Example do
      def run(arg) do
        case some_function(arg) do
          #{clauses}
        end
      end
    end
    """
  end

  describe "reports" do
    test "the example from the Elixir anti-patterns guide" do
      """
      defmodule Example do
        def run(arg) do
          case some_function(arg) do
            {:ok, value} -> value
            _ -> nil
          end
        end
      end
      """
      |> run()
      |> assert_issue(fn issue ->
        assert issue.trigger == "_"
        assert issue.line_no == 5
        assert issue.column == 7

        assert issue.message ==
                 "`case` matches `{:ok, ...}` and then everything else with `_`. " <>
                   "Match the error values explicitly, like `{:error, _}` or `:error`."
      end)
    end

    test "a named underscore variable" do
      "{:ok, value} -> value\n      _reason -> nil"
      |> in_function()
      |> run()
      |> assert_issue(fn issue ->
        assert issue.trigger == "_reason"
        assert issue.message =~ "everything else with `_reason`."
      end)
    end

    test "{:ok, ...} clauses that match any value" do
      for ok <- ["{:ok, _}", "{:ok, a, b}", "{:ok, _} = result", "result = {:ok, value}"] do
        "#{ok} -> :found\n      _ -> nil"
        |> in_function()
        |> run()
        |> assert_issue()
      end
    end

    test "functions that return :error, like Map.fetch/2" do
      """
      defmodule Example do
        def get(map, key, default) do
          case Map.fetch(map, key) do
            {:ok, value} -> value
            _ -> default
          end
        end
      end
      """
      |> run()
      |> assert_issue()
    end

    test "a generic {:ok, ...} clause after specific ones" do
      "{:ok, %{} = map} -> map\n      {:ok, nil} -> nil\n      {:ok, value} -> value\n      _ -> nil"
      |> in_function()
      |> run()
      |> assert_issue(fn issue -> assert issue.line_no == 7 end)
    end

    test "a catch-all that logs, or returns a variable named raise" do
      for fallback <- [~S|Logger.error("invalid")|, "raise", "Other.raise(\"invalid\")"] do
        "{:ok, value} -> value\n      _ ->\n        #{fallback}"
        |> in_function()
        |> run()
        |> assert_issue()
      end
    end

    test "other specific clauses before the catch-all" do
      "{:ok, value} -> value\n      nil -> :missing\n      _ -> nil"
      |> in_function()
      |> run()
      |> assert_issue()
    end

    test "a piped case, keyword syntax and nested cases" do
      """
      defmodule Example do
        def run(arg) do
          arg
          |> some_function()
          |> case do
            {:ok, value} ->
              case other(value), do: ({:ok, other} -> other; _ -> nil)

            _ ->
              nil
          end
        end
      end
      """
      |> run()
      |> assert_issues(fn issues ->
        assert issues |> Enum.map(& &1.line_no) |> Enum.sort() == [7, 9]
      end)
    end

    test "a case inside a quote" do
      """
      defmodule Example do
        defmacro fetch(expr) do
          quote do
            case unquote(expr) do
              {:ok, value} -> value
              _ -> nil
            end
          end
        end
      end
      """
      |> run()
      |> assert_issue()
    end

    test "test files when :exclude_test_files is false" do
      "{:ok, value} -> value\n      _ -> nil"
      |> in_function()
      |> run("test/example_test.exs", exclude_test_files: false)
      |> assert_issue()
    end
  end

  describe "does not report" do
    test "a case that matches the errors" do
      for error <- [
            "{:error, _}",
            ":error",
            "{:error, _, _}",
            "{:error, _} = error",
            "{:error, reason} when is_atom(reason)"
          ] do
        "{:ok, value} -> value\n      #{error} -> nil\n      _ -> nil"
        |> in_function()
        |> run()
        |> refute_issues()
      end
    end

    test "{:ok, ...} clauses that match specific values or have a guard" do
      for ok <- [
            "{:ok, true}",
            "{:ok, %{} = map}",
            "{:ok, [_ | _]}",
            "{:ok, ^expected}",
            "{:ok, __MODULE__}",
            "{:ok, value} when is_map(value)"
          ] do
        "#{ok} -> :found\n      _ -> nil"
        |> in_function()
        |> run()
        |> refute_issues()
      end
    end

    test "catch-all clauses that are not just an underscored variable" do
      for catch_all <- ["error -> error", "_ when is_nil(arg) -> nil", "__MODULE__ -> nil"] do
        "{:ok, value} -> value\n      #{catch_all}"
        |> in_function()
        |> run()
        |> refute_issues()
      end
    end

    test "a catch-all that raises" do
      for fallback <- [
            ~S|raise "not configured"|,
            "raise ArgumentError, \"invalid\"",
            "Logger.error(\"invalid\")\n        reraise error, __STACKTRACE__",
            ~S|Mix.raise("invalid")|
          ] do
        "{:ok, value} -> value\n      _ ->\n        #{fallback}"
        |> in_function()
        |> run()
        |> refute_issues()
      end
    end

    test "a catch-all before the {:ok, ...} clause" do
      "_ -> nil\n      {:ok, value} -> value"
      |> in_function()
      |> run()
      |> refute_issues()
    end

    test "a case without an {:ok, ...} clause" do
      for clause <- ["nil -> nil", ":ok -> :ok", "{:found, value} -> value"] do
        "#{clause}\n      _ -> :error"
        |> in_function()
        |> run()
        |> refute_issues()
      end
    end

    test "with, receive and multi-clause functions" do
      """
      defmodule Example do
        def run(arg) do
          with {:ok, value} <- some_function(arg) do
            value
          else
            _ -> nil
          end

          receive do
            {:ok, value} -> value
            _ -> nil
          end
        end

        def handle({:ok, value}), do: value
        def handle(_), do: nil
      end
      """
      |> run()
      |> refute_issues()
    end

    test "variables and functions named case, and clauses built with unquote" do
      """
      defmodule Example do
        def run(case) do
          Kernel.SpecialForms.case(case, do: [])
          Other.case(case, do: ({:ok, value} -> value; _ -> nil))
        end

        defmacro build(clauses) do
          quote do
            case some_function(), do: unquote(clauses)
          end
        end
      end
      """
      |> run()
      |> refute_issues()
    end

    test "test files" do
      "{:ok, value} -> value\n      _ -> nil"
      |> in_function()
      |> run("test/example_test.exs")
      |> refute_issues()
    end
  end
end
