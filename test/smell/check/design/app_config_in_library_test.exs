defmodule Smell.Check.Design.AppConfigInLibraryTest do
  use Credo.Test.Case

  @described_check Smell.Check.Design.AppConfigInLibrary

  @moduletag :tmp_dir

  @library """
  defmodule MyLib.MixProject do
    use Mix.Project

    def project do
      [app: :my_lib, version: "0.1.0", deps: deps(), package: package()]
    end

    defp deps, do: [{:jason, "~> 1.4"}]
    defp package, do: [licenses: ["MIT"]]
  end
  """

  setup %{tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, "mix.exs"), @library)
    %{path: Path.join(tmp_dir, "lib/my_lib.ex")}
  end

  defp run(source, path, params \\ []) do
    source
    |> to_source_file(path)
    |> run_check(@described_check, params)
  end

  describe "reports" do
    test "a function that reads the library's own environment", %{path: path} do
      """
      defmodule DashSplitter do
        def split(string) do
          parts = Application.fetch_env!(:my_lib, :parts)
          String.split(string, "-", parts: parts)
        end
      end
      """
      |> run(path)
      |> assert_issue(fn issue ->
        assert issue.trigger == "Application.fetch_env!"
        assert issue.line_no == 3
        assert issue.column == 13

        assert issue.message =~
                 "Library `:my_lib` reads `:parts` from its application environment"

        assert issue.message =~ "Accept it as an option"
      end)
    end

    test "every function that reads the environment", %{path: path} do
      """
      defmodule MyLib do
        def a, do: Application.get_env(:my_lib, :a)
        def b, do: Application.get_env(:my_lib, :b, 1)
        def c, do: Application.fetch_env(:my_lib, :c)
        def d, do: Application.fetch_env!(:my_lib, :d)
        def e, do: Application.get_all_env(:my_lib)
        def f, do: Application.compile_env(:my_lib, :f)
        def g, do: Application.compile_env(:my_lib, :g, 1)
        def h, do: Application.compile_env!(:my_lib, :h)
        def i, do: :application.get_env(:my_lib, :i)
        def j, do: :application.get_env(:my_lib, :j, 1)
        def k, do: :application.get_all_env(:my_lib)
      end
      """
      |> run(path)
      |> assert_issues(fn issues -> assert length(issues) == 11 end)
    end

    test "reads that decide more than whether to print a warning", %{path: path} do
      """
      defmodule MyLib do
        def a(key) do
          if Application.get_env(:my_lib, :strict) do
            raise "invalid key: \#{key}"
          end
        end

        def b do
          case Application.get_env(:my_lib, :parts) do
            nil -> IO.warn("no parts")
            parts -> parts
          end
        end

        def c do
          if Application.get_env(:my_lib, :verbose), do: IO.warn("x"), else: setup()
        end
      end
      """
      |> run(path)
      |> assert_issues(fn issues -> assert length(issues) == 3 end)
    end

    test "the Erlang API, with the trigger at the module", %{path: path} do
      """
      defmodule MyLib do
        def parts, do: :application.get_env(:my_lib, :parts)
      end
      """
      |> run(path)
      |> assert_issue(fn issue ->
        assert issue.trigger == ":application.get_env"
        assert issue.column == 18
      end)
    end

    test "a read at compile time", %{path: path} do
      """
      defmodule MyLib do
        @parts Application.compile_env(:my_lib, :parts, 2)
        @debug Application.get_env(:my_lib, :debug)

        defmacro parts do
          Application.get_env(:my_lib, :parts)
        end

        defmacro __using__(_opts) do
          quote do
            defmacro debug, do: Application.get_env(:my_lib, :debug)
          end
        end
      end
      """
      |> run(path)
      |> assert_issues(fn issues ->
        assert length(issues) == 4
        assert Enum.all?(issues, &(&1.message =~ "at compile time"))
      end)
    end

    test "a read inside unquote, which runs when the macro expands", %{path: path} do
      """
      defmodule MyLib do
        defmacro parts do
          quote do
            def parts, do: unquote(Application.get_env(:my_lib, :parts))
          end
        end
      end
      """
      |> run(path)
      |> assert_issue(fn issue -> assert issue.message =~ "at compile time" end)
    end

    test "compile_env/4 and compile_env!/3, which take __ENV__ first", %{path: path} do
      """
      defmodule MyLib do
        defmacro a, do: Application.compile_env(__ENV__, :my_lib, :a, 1)
        defmacro b, do: Application.compile_env!(__ENV__, :my_lib, :b)
      end
      """
      |> run(path)
      |> assert_issues(fn issues -> assert length(issues) == 2 end)
    end

    test "a read in code that the library generates", %{path: path} do
      """
      defmodule MyLib do
        defmacro __using__(_opts) do
          quote do
            def parts, do: Application.get_env(:my_lib, :parts)
          end
        end
      end
      """
      |> run(path)
      |> assert_issue(fn issue -> assert issue.message =~ "Accept it as an option instead (" end)
    end

    test "a read in a default argument", %{path: path} do
      """
      defmodule MyLib do
        def split(string, parts \\\\ Application.get_env(:my_lib, :parts)) do
          String.split(string, "-", parts: parts)
        end
      end
      """
      |> run(path)
      |> assert_issue()
    end

    test "a piped app name", %{path: path} do
      """
      defmodule MyLib do
        def parts, do: :my_lib |> Application.get_env(:parts)
      end
      """
      |> run(path)
      |> assert_issue(fn issue -> assert issue.trigger == "Application.get_env" end)
    end

    test "the app name in a module attribute", %{path: path} do
      """
      defmodule MyLib do
        @app :my_lib
        def parts, do: Application.get_env(@app, :parts)
      end
      """
      |> run(path)
      |> assert_issue()
    end

    test "Elixir.Application, even when Application is an alias", %{path: path} do
      """
      defmodule MyLib do
        alias MyLib.Application
        def parts, do: Elixir.Application.get_env(:my_lib, :parts)
      end
      """
      |> run(path)
      |> assert_issue(fn issue ->
        assert issue.trigger == "Elixir.Application.get_env"
        assert issue.column == 18
      end)
    end

    test "a key path, described in full", %{path: path} do
      """
      defmodule MyLib.Backoff do
        @retry Application.compile_env(:my_lib, [MyLib.Backoff, :retry_mult], 100)
      end
      """
      |> run(path)
      |> assert_issue(fn issue -> assert issue.message =~ "`[MyLib.Backoff, :retry_mult]`" end)
    end

    test "the whole environment", %{path: path} do
      """
      defmodule MyLib do
        def config, do: Application.get_all_env(:my_lib)
      end
      """
      |> run(path)
      |> assert_issue(fn issue -> assert issue.message =~ "reads all keys from" end)
    end

    test "Mix tasks, pointing to Mix.Project.config/0", %{tmp_dir: tmp_dir} do
      """
      defmodule Mix.Tasks.MyLib.Gen do
        use Mix.Task

        def run(_args), do: Application.get_env(:my_lib, :output)
      end
      """
      |> run(Path.join(tmp_dir, "lib/mix/tasks/my_lib.gen.ex"))
      |> assert_issue(fn issue ->
        assert issue.message =~
                 "Mix task reads `:output` from the `:my_lib` application environment"

        assert issue.message =~ "Mix.Project.config/0"
      end)
    end

    test "nested Mix task modules", %{path: path} do
      """
      defmodule Mix.Tasks do
        defmodule MyLib.Gen do
          def run(_args), do: Application.get_env(:my_lib, :output)
        end
      end
      """
      |> run(path)
      |> assert_issue(fn issue -> assert issue.message =~ "Mix task" end)
    end

    test "an app name set with a module attribute in mix.exs", %{tmp_dir: tmp_dir} do
      dir = Path.join(tmp_dir, "attr")
      File.mkdir_p!(dir)

      File.write!(Path.join(dir, "mix.exs"), """
      defmodule MyLib.MixProject do
        use Mix.Project
        @app :other_lib
        def project, do: [app: @app, version: "0.1.0", package: [licenses: ["MIT"]]]
      end
      """)

      """
      defmodule OtherLib do
        def parts, do: Application.get_env(:other_lib, :parts)
      end
      """
      |> run(Path.join(dir, "lib/other_lib.ex"))
      |> assert_issue()
    end

    test "each app of an umbrella with its own mix.exs", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "mix.exs"), """
      defmodule Umbrella.MixProject do
        use Mix.Project
        def project, do: [apps_path: "apps", version: "0.1.0"]
      end
      """)

      dir = Path.join(tmp_dir, "apps/child")
      File.mkdir_p!(dir)

      File.write!(Path.join(dir, "mix.exs"), """
      defmodule Child.MixProject do
        use Mix.Project
        def project, do: [app: :child, version: "0.1.0", package: [licenses: ["MIT"]]]
      end
      """)

      """
      defmodule Child do
        def parts, do: Application.get_env(:child, :parts)
      end
      """
      |> run(Path.join(dir, "lib/child.ex"))
      |> assert_issue()
    end

    test "an application project when :library is true", %{tmp_dir: tmp_dir} do
      dir = Path.join(tmp_dir, "app")
      File.mkdir_p!(dir)

      File.write!(Path.join(dir, "mix.exs"), """
      defmodule MyApp.MixProject do
        use Mix.Project
        def project, do: [app: :my_app, version: "0.1.0"]
      end
      """)

      """
      defmodule MyApp do
        def parts, do: Application.get_env(:my_app, :parts)
      end
      """
      |> run(Path.join(dir, "lib/my_app.ex"), library: true)
      |> assert_issue()
    end

    test "test files when :exclude_test_files is false", %{tmp_dir: tmp_dir} do
      """
      defmodule MyLibTest do
        def parts, do: Application.get_env(:my_lib, :parts)
      end
      """
      |> run(Path.join(tmp_dir, "test/my_lib_test.exs"), exclude_test_files: false)
      |> assert_issue()
    end
  end

  describe "does not report" do
    test "the environment of other applications", %{path: path} do
      """
      defmodule MyLib do
        def level, do: Application.get_env(:logger, :level)
        def trim, do: Application.get_env(:phoenix, :trim_on_html_eex_engine, true)
      end
      """
      |> run(path)
      |> refute_issues()
    end

    test "the :otp_app pattern", %{path: path} do
      """
      defmodule MyLib.Repo do
        defmacro __using__(opts) do
          otp_app = Keyword.fetch!(opts, :otp_app)

          quote do
            @otp_app unquote(otp_app)
            def config, do: Application.get_env(@otp_app, __MODULE__, [])
            def url, do: Application.get_env(unquote(otp_app), :url)
          end
        end

        def config(otp_app), do: Application.get_env(otp_app, __MODULE__, [])
      end
      """
      |> run(path)
      |> refute_issues()
    end

    test "an app name that the macro unquotes", %{path: path} do
      """
      defmodule MyLib do
        defmacro config(app) do
          quote do
            Application.get_env(unquote(app), :key)
          end
        end
      end
      """
      |> run(path)
      |> refute_issues()
    end

    test "reads that only decide whether to print a warning", %{path: path} do
      """
      defmodule MyLib do
        if Application.compile_env(:my_lib, :mimes) do
          IO.puts(:stderr, "the :mimes configuration is no longer supported")
        end

        def a do
          case Application.get_env(:my_lib, :colocated_js) do
            nil -> :ok
            _ -> IO.warn("the :colocated_js configuration is deprecated")
          end
        end

        def b(level) do
          if level != nil and not Application.get_env(:my_lib, :disable_warning, false) do
            IO.warn(":log_level is deprecated")
          end
        end

        def c, do: unless(Application.get_env(:my_lib, :quiet), do: IO.warn("deprecated"))
      end
      """
      |> run(path)
      |> refute_issues()
    end

    test "keys that swap a component", %{path: path} do
      """
      defmodule MyLib do
        def a, do: Application.get_env(:my_lib, :adapter)
        def b, do: Application.get_env(:my_lib, :json_library, Jason)
        def c, do: Application.fetch_env!(:my_lib, :http_client)
        def d, do: Application.get_env(:my_lib, :awscli_auth_adapter)
        def e, do: Application.get_env(:my_lib, :json_codec)
        @f Application.compile_env(:my_lib, [MyLib.Mailer, :adapter])
      end
      """
      |> run(path)
      |> refute_issues()
    end

    test "keys that only look like component keys", %{path: path} do
      """
      defmodule MyLib do
        def a, do: Application.get_env(:my_lib, :adapter_opts)
        def b, do: Application.get_env(:my_lib, :readapter)
      end
      """
      |> run(path)
      |> assert_issues(fn issues -> assert length(issues) == 2 end)
    end

    test "keys in :allowed_keys", %{path: path} do
      """
      defmodule MyLib do
        def a, do: Application.get_env(:my_lib, :debug)
        def b, do: Application.get_env(:my_lib, :statuses)
        def c, do: Application.get_env(:my_lib, :serve_mailbox)
        def d, do: Application.get_env(:my_lib, MyLib.Logger)
        @e Application.compile_env(:my_lib, [MyLib.Backoff, :retry_mult], 100)
      end
      """
      |> run(path,
        allowed_keys: [:debug, "statuses", ~r/^serve_/, MyLib.Logger, :retry_mult]
      )
      |> refute_issues()
    end

    test "application projects", %{tmp_dir: tmp_dir} do
      for {name, project} <- [
            no_package: ~s([app: :my_app, version: "0.1.0"]),
            releases: ~s([app: :my_app, package: [], releases: [my_app: []]])
          ] do
        dir = Path.join(tmp_dir, "#{name}")
        File.mkdir_p!(dir)

        File.write!(Path.join(dir, "mix.exs"), """
        defmodule MyApp.MixProject do
          use Mix.Project
          def project, do: #{project}
        end
        """)

        """
        defmodule MyApp do
          def parts, do: Application.get_env(:my_app, :parts)
        end
        """
        |> run(Path.join(dir, "lib/my_app.ex"))
        |> refute_issues()
      end
    end

    test "projects without a mix.exs, even when :library is true" do
      """
      defmodule MyLib do
        def parts, do: Application.get_env(:my_lib, :parts)
      end
      """
      |> run("/smell-no-project/lib/my_lib.ex", library: true)
      |> refute_issues()
    end

    test "projects whose mix.exs does not parse", %{tmp_dir: tmp_dir} do
      dir = Path.join(tmp_dir, "broken")
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "mix.exs"), "defmodule Broken do def project, do: [app: :my_lib")

      """
      defmodule MyLib do
        def parts, do: Application.get_env(:my_lib, :parts)
      end
      """
      |> run(Path.join(dir, "lib/my_lib.ex"))
      |> refute_issues()
    end

    test "anything when :library is false", %{path: path} do
      """
      defmodule MyLib do
        def parts, do: Application.get_env(:my_lib, :parts)
      end
      """
      |> run(path, library: false)
      |> refute_issues()
    end

    test "test files", %{tmp_dir: tmp_dir} do
      """
      defmodule MyLibTest do
        def parts, do: Application.get_env(:my_lib, :parts)
      end
      """
      |> run(Path.join(tmp_dir, "test/my_lib_test.exs"))
      |> refute_issues()
    end

    test "an Application module that is an alias", %{path: path} do
      for alias_code <- [
            "alias MyLib.Application",
            "alias MyLib.Config, as: Application",
            "alias MyLib.{Application, Repo}",
            "defmodule Application, do: def(get_env(_app, _key), do: nil)"
          ] do
        """
        defmodule MyLib do
          #{alias_code}
          def parts, do: Application.get_env(:my_lib, :parts)
        end
        """
        |> run(path)
        |> refute_issues()
      end
    end

    test "functions that only share the name", %{path: path} do
      """
      defmodule MyLib do
        def get_env(app, key), do: {app, key}
        def a, do: get_env(:my_lib, :parts)
        def b, do: MyLib.Config.get_env(:my_lib, :parts)
        def c, do: Application.put_env(:my_lib, :parts, 3)
        def d, do: Application.get_env(:other, :my_lib)
        def e(application), do: application.get_env(:my_lib, :parts)
        def f, do: Application.get_application(__MODULE__)
      end
      """
      |> run(path)
      |> refute_issues()
    end
  end

  test "an alias with :as to another name keeps Application", %{path: path} do
    """
    defmodule MyLib do
      alias MyLib.Application, as: App
      def parts, do: Application.get_env(:my_lib, :parts)
    end
    """
    |> run(path)
    |> assert_issue()
  end
end
