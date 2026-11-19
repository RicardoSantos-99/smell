defmodule Smell.Check.Refactor.SendingUnnecessaryDataTest do
  use Credo.Test.Case

  @described_check Smell.Check.Refactor.SendingUnnecessaryData

  defp run(source, filename \\ "lib/my_app.ex", params \\ []) do
    source
    |> to_source_file(filename)
    |> run_check(@described_check, params)
  end

  # `call` goes on line 3, inside a function with `conn`, `state` and `socket`.
  defp in_function(call) do
    """
    defmodule MyApp do
      def report(conn, state, socket, list, sup, agent) do
        #{call}
      end
    end
    """
  end

  describe "reports" do
    test "the example of the documentation" do
      "spawn(fn -> log_request_ip(conn.remote_ip) end)"
      |> in_function()
      |> run()
      |> assert_issue(fn issue ->
        assert issue.trigger == "conn"
        assert issue.line_no == 3
        assert issue.column == 32

        assert issue.message ==
                 "The function given to `spawn/1` captures `conn` only to read " <>
                   "`conn.remote_ip`, so all of `conn` is copied to the process that " <>
                   "runs it. Read the field into a variable before the function."
      end)
    end

    test "several fields, nested fields and a field read twice" do
      """
      defmodule MyApp do
        def notify(state) do
          Task.start(fn ->
            post(state.config.url, state.owner)
            log(state.owner)
          end)
        end
      end
      """
      |> run()
      |> assert_issue(fn issue ->
        assert issue.line_no == 4
        assert issue.column == 12

        assert issue.message =~
                 "captures `state` only to read `state.config` and `state.owner`, "

        assert issue.message =~ "Read the fields into variables before the function."
      end)
    end

    test "every function that runs the function in another process" do
      for {call, name} <- [
            {"spawn(fn -> log(conn.remote_ip) end)", "spawn/1"},
            {"spawn_link(fn -> log(conn.remote_ip) end)", "spawn_link/1"},
            {"spawn_monitor(fn -> log(conn.remote_ip) end)", "spawn_monitor/1"},
            {"Kernel.spawn(fn -> log(conn.remote_ip) end)", "Kernel.spawn/1"},
            {":erlang.spawn(fn -> log(conn.remote_ip) end)", ":erlang.spawn/1"},
            {":erlang.spawn_opt(fn -> log(conn.remote_ip) end, [:link])", ":erlang.spawn_opt/2"},
            {"Process.spawn(fn -> log(conn.remote_ip) end, [:link])", "Process.spawn/2"},
            {"Node.spawn(node(), fn -> log(conn.remote_ip) end)", "Node.spawn/2"},
            {"Task.async(fn -> log(conn.remote_ip) end)", "Task.async/1"},
            {"Task.start(fn -> log(conn.remote_ip) end)", "Task.start/1"},
            {"Task.start_link(fn -> log(conn.remote_ip) end)", "Task.start_link/1"},
            {"Task.async_stream(list, fn x -> log(x, conn.remote_ip) end, max_concurrency: 2)",
             "Task.async_stream/3"},
            {"Task.Supervisor.async(sup, fn -> log(conn.remote_ip) end)",
             "Task.Supervisor.async/2"},
            {"Task.Supervisor.async_nolink(sup, fn -> log(conn.remote_ip) end, [])",
             "Task.Supervisor.async_nolink/3"},
            {"Task.Supervisor.start_child(sup, fn -> log(conn.remote_ip) end)",
             "Task.Supervisor.start_child/2"},
            {"Task.Supervisor.async_stream(sup, list, fn x -> log(x, conn.remote_ip) end)",
             "Task.Supervisor.async_stream/3"},
            {"Task.Supervisor.async_stream_nolink(sup, list, fn x -> log(x, conn.remote_ip) end)",
             "Task.Supervisor.async_stream_nolink/3"},
            {"Agent.start_link(fn -> %{ip: conn.remote_ip} end, name: Ips)",
             "Agent.start_link/2"},
            {"Agent.get(agent, fn ips -> Map.get(ips, conn.remote_ip) end)", "Agent.get/2"},
            {"Agent.update(agent, fn ips -> Map.put(ips, conn.remote_ip, 1) end)",
             "Agent.update/2"},
            {"Agent.get_and_update(agent, fn ips -> Map.pop(ips, conn.remote_ip) end)",
             "Agent.get_and_update/2"},
            {"Agent.cast(agent, fn ips -> Map.delete(ips, conn.remote_ip) end)", "Agent.cast/2"},
            {"start_async(socket, :ip, fn -> lookup(conn.remote_ip) end)", "start_async/3"},
            {"assign_async(socket, :ip, fn -> lookup(conn.remote_ip) end)", "assign_async/3"},
            {"Phoenix.LiveView.start_async(socket, :ip, fn -> lookup(conn.remote_ip) end)",
             "Phoenix.LiveView.start_async/3"}
          ] do
        call
        |> in_function()
        |> run()
        |> assert_issue(fn issue ->
          assert issue.message =~ "The function given to `#{name}` captures `conn`", call
          assert issue.line_no == 3
        end)
      end
    end

    test "piped calls, captures and other closures" do
      for {call, name} <- [
            {"list |> Task.async_stream(fn x -> log(x, conn.remote_ip) end)",
             "Task.async_stream/2"},
            {"sup |> Task.Supervisor.async(fn -> log(conn.remote_ip) end)",
             "Task.Supervisor.async/2"},
            {"socket |> assign_async(:ip, fn -> lookup(conn.remote_ip) end)", "assign_async/3"},
            {"list |> Enum.take(2) |> Task.async_stream(&log(&1, conn.remote_ip))",
             "Task.async_stream/2"},
            {"Task.async(&log(conn.remote_ip, &1))", "Task.async/1"},
            {"Task.async(fn -> \"\#{conn.remote_ip}\" end)", "Task.async/1"},
            {"Task.async(fn -> cond do conn.halted -> :halted; true -> :ok end end)",
             "Task.async/1"},
            {"Task.async(fn x when x > 0 -> log(x, conn.remote_ip) end)", "Task.async/1"},
            {"Task.async(fn -> Enum.map(list, fn x -> {x, conn.remote_ip} end) end)",
             "Task.async/1"},
            {"Task.async(fn -> fetch(socket.assigns.user) end)", "Task.async/1"},
            {"Task.async(fn -> state.module.run() end)", "Task.async/1"},
            {"Task.async_stream(list, fn x when x > conn.port -> x end)", "Task.async_stream/2"},
            {"Task.async(fn -> log(@conn, conn.remote_ip) end)", "Task.async/1"},
            {"spawn(fn -> receive do @conn -> log(conn.remote_ip) end end)", "spawn/1"}
          ] do
        call
        |> in_function()
        |> run()
        |> assert_issue(fn issue ->
          assert issue.message =~ "The function given to `#{name}` captures", call
        end)
      end
    end

    test "one issue per variable, at its first use" do
      """
      defmodule MyApp do
        def report(conn, state) do
          Task.async(fn ->
            send(state.pid, conn.remote_ip)
            log(conn.method)
          end)
        end
      end
      """
      |> run()
      |> assert_issues(fn issues ->
        assert issues |> Enum.map(&{&1.trigger, &1.line_no, &1.column}) |> Enum.sort() == [
                 {"conn", 4, 23},
                 {"state", 4, 12}
               ]
      end)
    end

    test "a function inside another one, once" do
      """
      defmodule MyApp do
        def report(conn) do
          Task.async(fn ->
            spawn(fn -> log(conn.remote_ip) end)
          end)
        end
      end
      """
      |> run()
      |> assert_issue(fn issue ->
        assert issue.message =~ "given to `Task.async/1`"
        assert issue.line_no == 4
      end)
    end

    test "functions generated by a quote" do
      """
      defmodule MyApp do
        defmacro __using__(_opts) do
          quote do
            def report(conn), do: spawn(fn -> log(conn.remote_ip) end)
          end
        end
      end
      """
      |> run()
      |> assert_issue(fn issue -> assert issue.line_no == 4 end)
    end

    test "test files when :exclude_test_files is false" do
      "spawn(fn -> log(conn.remote_ip) end)"
      |> in_function()
      |> run("test/support/my_app.ex", exclude_test_files: false)
      |> assert_issue()
    end
  end

  describe "does not report" do
    test "a variable that the function also uses whole" do
      for call <- [
            "spawn(fn -> log_request_ip(conn) end)",
            "spawn(fn -> log(conn.remote_ip, conn) end)",
            "spawn(fn -> %{state | count: state.count + 1} end)",
            "spawn(fn -> %{remote_ip: ip} = conn; log(ip, conn.method) end)",
            "spawn(fn -> receive do ^conn -> log(conn.remote_ip) end end)",
            "spawn(fn -> conn[:remote_ip] end)",
            "spawn(fn -> Map.get(conn, :remote_ip) end)",
            "spawn(fn -> conn.halt() end)"
          ] do
        call
        |> in_function()
        |> run()
        |> refute_issues()
      end
    end

    test "variables that the function binds" do
      for call <- [
            "spawn(fn -> conn = build(); log(conn.remote_ip) end)",
            "Task.async_stream(list, fn conn -> log(conn.remote_ip) end)",
            "Task.async_stream(list, fn %{conn: conn} when is_map(conn) -> log(conn.remote_ip) end)",
            "spawn(fn -> case fetch() do {:ok, conn} -> log(conn.remote_ip) end end)",
            "spawn(fn -> for conn <- list, do: log(conn.remote_ip) end)",
            "spawn(fn -> with {:ok, conn} <- fetch(), do: log(conn.remote_ip) end)",
            "spawn(fn -> receive do {:conn, conn} -> log(conn.remote_ip) end end)",
            "spawn(fn -> Enum.each(list, fn conn -> log(conn.remote_ip) end) end)",
            "spawn(fn -> log(conn.remote_ip); conn = build(); log(conn.method) end)"
          ] do
        call
        |> in_function()
        |> run()
        |> refute_issues()
      end
    end

    test "functions that do not run in another process" do
      for call <- [
            "Enum.map(list, fn x -> {x, conn.remote_ip} end)",
            "Task.await(Task.async(&work/0))",
            "send(agent, {:report, conn})",
            "GenServer.cast(agent, {:report, conn.remote_ip})",
            "Task.async_stream(list, &fetch/1)",
            "Task.async_stream(list, &state.handle/1)",
            "Task.async(fn -> log(__ENV__.file, __MODULE__) end)",
            "Task.async_stream(list, Fetcher, :fetch, [conn.remote_ip])",
            "Task.Supervisor.async(sup, Fetcher, :fetch, [conn.remote_ip])",
            "Agent.get(agent, Fetcher, :fetch, [conn.remote_ip])",
            "spawn(Fetcher, :fetch, [conn.remote_ip])",
            "Task.async(fn -> @config.timeout end)",
            "start_async(socket, :user, fn -> fetch(socket.assigns.user) end)",
            "socket |> assign_async(:user, fn -> fetch(socket.assigns.user) end)"
          ] do
        call
        |> in_function()
        |> run()
        |> refute_issues()
      end
    end

    test "variables and modules named like the functions" do
      for call <- [
            "spawn = &Kernel.spawn/1; spawn.(fn -> log(conn.remote_ip) end)",
            "task.async(fn -> log(conn.remote_ip) end)",
            "MyApp.Task.async(fn -> log(conn.remote_ip) end)",
            "__MODULE__.spawn(fn -> log(conn.remote_ip) end)",
            "state.supervisor.async(sup, fn -> log(conn.remote_ip) end)",
            "Task.async(unquote_splicing(list))"
          ] do
        call
        |> in_function()
        |> run()
        |> refute_issues()
      end
    end

    test "test files" do
      "spawn(fn -> log(conn.remote_ip) end)"
      |> in_function()
      |> run("test/my_app_test.exs")
      |> refute_issues()
    end
  end
end
