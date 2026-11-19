defmodule Smell.Check.Design.BooleanObsessionTest do
  use Credo.Test.Case

  @described_check Smell.Check.Design.BooleanObsession

  defp run(source, filename \\ "lib/my_app.ex", params \\ []) do
    source
    |> to_source_file(filename)
    |> run_check(@described_check, params)
  end

  # A `cond` over two options, on line 4, column 5. `before` goes on line 3.
  defp in_cond(first, second, before \\ ":ok", head \\ "process(invoice, opts)") do
    """
    defmodule MyApp do
      def #{head} do
        #{before}
        cond do
          #{first} -> approve(invoice)
          #{second} -> review(invoice)
          true -> invoice
        end
      end
    end
    """
  end

  describe "reports" do
    test "a cond over boolean options" do
      """
      defmodule MyApp do
        def process(invoice, options \\\\ []) do
          cond do
            options[:admin] -> approve(invoice)
            options[:editor] -> review(invoice)
            true -> invoice
          end
        end
      end
      """
      |> run()
      |> assert_issue(fn issue ->
        assert issue.trigger == "cond"
        assert issue.line_no == 3
        assert issue.column == 5

        assert issue.message ==
                 "The boolean options `:admin` and `:editor` of `options` have " <>
                   "overlapping states. Use one option that takes an atom instead."
      end)
    end

    test "three options in the message" do
      """
      defmodule Plug.Conn do
        def configure_session(conn, opts) do
          cond do
            opts[:renew] -> put_private(conn, :plug_session_info, :renew)
            opts[:drop] -> put_private(conn, :plug_session_info, :drop)
            opts[:ignore] -> put_private(conn, :plug_session_info, :ignore)
            true -> conn
          end
        end
      end
      """
      |> run()
      |> assert_issue(fn issue ->
        assert issue.message =~ "options `:renew`, `:drop` and `:ignore` of `opts`"
      end)
    end

    test "every way to read an option" do
      for {first, before} <- [
            {"opts[:admin]", ":ok"},
            {"Keyword.get(opts, :admin)", ":ok"},
            {"Keyword.get(opts, :admin, false)", ":ok"},
            {"Keyword.get(opts, :admin, true)", ":ok"},
            {"Keyword.get(opts, :admin, nil)", ":ok"},
            {"opts[:admin] == true", ":ok"},
            {"Keyword.get(opts, :admin) === false", ":ok"},
            {"admin?", "admin? = opts[:admin]"},
            {"admin?", "admin? = Keyword.get(opts, :admin, false)"},
            {"admin?", "{admin?, opts} = Keyword.pop(opts, :admin, false)"},
            {"admin?", "{admin?, _opts} = Keyword.pop(opts, :admin)"},
            {"admin? == false", "admin? = opts[:admin]"}
          ] do
        first
        |> in_cond("opts[:editor]", before)
        |> run()
        |> assert_issue(fn issue ->
          assert issue.message =~ "`:admin` and `:editor` of `opts`", first
          assert issue.line_no == 4
          assert issue.column == 5
        end)
      end
    end

    test "every way to declare the options parameter" do
      for head <- [
            "process(invoice, opts \\\\ [])",
            "process(invoice, opts) when is_list(opts)",
            "process(invoice, [_ | _] = opts)",
            "process(invoice, opts = %{})",
            "process(%Invoice{} = invoice, opts)"
          ] do
        "opts[:admin]"
        |> in_cond("opts[:editor]", ":ok", head)
        |> run()
        |> assert_issue()
      end
    end

    test "private functions, macros and the keyword syntax" do
      """
      defmodule MyApp do
        defp process(invoice, opts) do
          cond do
            opts[:admin] -> approve(invoice)
            opts[:editor] -> review(invoice)
            true -> invoice
          end
        end

        defmacro route(path, opts) do
          cond do
            opts[:live] -> live_route(path)
            opts[:static] -> static_route(path)
            true -> route(path)
          end
        end

        def mode(opts), do: (cond do opts[:fast] -> :fast; opts[:safe] -> :safe; true -> :default end)
      end
      """
      |> run()
      |> assert_issues(fn issues ->
        assert issues |> Enum.map(& &1.line_no) |> Enum.sort() == [3, 11, 18]
      end)
    end

    test "a case on a tuple of boolean options" do
      """
      defmodule Plug.Conn.Cookies do
        def sign_or_encrypt(conn, key, value, opts) do
          {sign?, opts} = Keyword.pop(opts, :sign, false)
          {encrypt?, opts} = Keyword.pop(opts, :encrypt, false)

          case {sign?, encrypt?} do
            {true, true} -> raise ArgumentError, ":encrypt implies :sign"
            {true, false} -> {sign(conn, key, value), opts}
            {false, true} -> {encrypt(conn, key, value), opts}
            {false, false} -> {value, opts}
          end
        end
      end
      """
      |> run()
      |> assert_issue(fn issue ->
        assert issue.trigger == "case"
        assert issue.line_no == 6
        assert issue.column == 5
        assert issue.message =~ "`:sign` and `:encrypt` of `opts`"
      end)
    end

    test "a case on three options, with guards and catch-alls" do
      """
      defmodule Summary do
        def web(opts) do
          case {opts[:html], Keyword.get(opts, :live), opts[:assets]} do
            {true, _, _} -> "HTML"
            {_, true, _} when is_list(opts) -> "LiveView"
            {_, _, false} -> "No assets"
            {_, _, _} -> "API-only"
          end
        end
      end
      """
      |> run()
      |> assert_issue(fn issue ->
        assert issue.message =~ "`:html`, `:live` and `:assets` of `opts`"
      end)
    end

    test "functions generated by a quote, once each" do
      """
      defmodule MyApp do
        defmacro __using__(opts) do
          quote do
            def process(invoice, opts) do
              cond do
                opts[:admin] -> approve(invoice)
                opts[:editor] -> review(invoice)
                true -> invoice
              end
            end
          end
        end
      end
      """
      |> run()
      |> assert_issue(fn issue -> assert issue.line_no == 5 end)
    end

    test "one issue per options parameter" do
      """
      defmodule MyApp do
        def process(invoice, opts, config) do
          cond do
            opts[:admin] -> approve(invoice)
            config[:strict] -> reject(invoice)
            opts[:editor] -> review(invoice)
            config[:lenient] -> accept(invoice)
            true -> invoice
          end
        end
      end
      """
      |> run()
      |> assert_issues(fn issues ->
        assert issues |> Enum.map(& &1.message) |> Enum.sort() == [
                 "The boolean options `:admin` and `:editor` of `opts` have overlapping " <>
                   "states. Use one option that takes an atom instead.",
                 "The boolean options `:strict` and `:lenient` of `config` have overlapping " <>
                   "states. Use one option that takes an atom instead."
               ]
      end)
    end

    test "test files when :exclude_test_files is false" do
      "opts[:admin]"
      |> in_cond("opts[:editor]")
      |> run("test/support/my_app.ex", exclude_test_files: false)
      |> assert_issue()
    end
  end

  describe "does not report" do
    test "a single option, or the same option twice" do
      for {first, second} <- [
            {"opts[:admin]", "invoice.paid?"},
            {"opts[:admin]", "Keyword.get(opts, :admin) == false"},
            {"opts[:admin]", "opts[:admin] == nil"}
          ] do
        first
        |> in_cond(second)
        |> run()
        |> refute_issues()
      end
    end

    test "options whose value the branch uses" do
      for use <- [
            "list(opts[:values])",
            "list(Keyword.get(opts, :values, []))",
            "list(Keyword.fetch!(opts, :values))",
            "elem(Keyword.pop(opts, :values), 0)"
          ] do
        """
        defmodule Declarative do
          def build_values(opts) do
            cond do
              Keyword.get(opts, :values) -> ["Must be one of ", #{use}]
              opts[:required] -> ["Required"]
              true -> []
            end
          end
        end
        """
        |> run()
        |> refute_issues()
      end

      """
      defmodule Declarative do
        def build(opts) do
          values = opts[:values]
          examples = Keyword.get(opts, :examples)

          cond do
            values -> list(values)
            examples -> list(examples)
            true -> []
          end
        end
      end
      """
      |> run()
      |> refute_issues()
    end

    test "options with a default that is not a boolean" do
      "Keyword.get(opts, :admin, :none)"
      |> in_cond("opts[:editor]")
      |> run()
      |> refute_issues()

      "admin?"
      |> in_cond("opts[:editor]", "{admin?, opts} = Keyword.pop(opts, :admin, [])")
      |> run()
      |> refute_issues()
    end

    test "fields of structs and maps" do
      for {first, second} <- [
            {"opts.admin", "opts.editor"},
            {"Map.get(opts, :admin)", "Map.get(opts, :editor)"},
            {"invoice.admin?", "invoice.editor?"},
            {~s(opts["admin"]), ~s(opts["editor"])}
          ] do
        first
        |> in_cond(second)
        |> run()
        |> refute_issues()
      end
    end

    test "options that are not a parameter of the function" do
      """
      defmodule Mix.Tasks.Checksum do
        def run(flags) do
          {options, _args} = OptionParser.parse!(flags, strict: [all: :boolean, only_local: :boolean])

          cond do
            Keyword.get(options, :all) -> all_urls()
            Keyword.get(options, :only_local) -> local_urls()
            true -> Mix.raise("pass --all or --only-local")
          end
        end

        defp correct_closing({form, meta, args}) do
          cond do
            meta[:do] -> {form, meta, args}
            meta[:closing] -> {form, put_in(meta, [:closing, :line], 1), args}
            true -> {form, meta, args}
          end
        end

        def process(invoice, _opts) do
          fn opts ->
            cond do
              opts[:admin] -> approve(invoice)
              opts[:editor] -> review(invoice)
              true -> invoice
            end
          end
        end
      end
      """
      |> run()
      |> refute_issues()
    end

    test "conditions that combine options" do
      """
      defmodule MyApp do
        def process(invoice, opts) do
          cond do
            opts[:admin] and opts[:editor] -> raise ArgumentError
            not opts[:admin] -> review(invoice)
            !opts[:editor] -> approve(invoice)
            true -> invoice
          end
        end
      end
      """
      |> run()
      |> refute_issues()
    end

    test "a case that does not match every option against a boolean" do
      """
      defmodule Plug.Cowboy do
        defp set_stream_handlers(opts) do
          compress = Keyword.get(opts, :compress)
          stream_handlers = Keyword.get(opts, :stream_handlers)

          case {compress, stream_handlers} do
            {true, nil} -> Keyword.put_new(opts, :stream_handlers, [:cowboy_compress_h])
            {true, _} -> raise "cannot set both compress and stream_handlers"
            {_, nil} -> Keyword.put_new(opts, :stream_handlers, [])
            {_, _} -> opts
          end
        end

        def summary(opts, state) do
          case {opts[:html], state} do
            {true, true} -> :html
            {_, _} -> :other
          end
        end

        def html(opts) do
          case opts[:html] do
            true -> :html
            false -> :api
          end
        end

        def variants(opts) do
          case {opts[:html], opts[:live]} do
            {:yes, :yes} -> :live
            other -> other
          end
        end
      end
      """
      |> run()
      |> refute_issues()
    end

    test "test files" do
      "opts[:admin]"
      |> in_cond("opts[:editor]")
      |> run("test/support/my_app.ex")
      |> refute_issues()
    end
  end
end
