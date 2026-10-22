defmodule Smell.Check.Readability.ComplexElseClausesTest do
  use Credo.Test.Case

  @described_check Smell.Check.Readability.ComplexElseClauses

  describe "reports" do
    test "the example from the Elixir anti-patterns guide" do
      """
      defmodule Example do
        def open_decoded_file(path) do
          with {:ok, encoded} <- File.read(path),
               {:ok, decoded} <- Base.decode64(encoded) do
            {:ok, String.trim(decoded)}
          else
            {:error, _} -> {:error, :badfile}
            :error -> {:error, :badencoding}
          end
        end
      end
      """
      |> to_source_file()
      |> run_check(@described_check)
      |> assert_issue(fn issue ->
        assert issue.line_no == 3
        assert issue.trigger == "with"
      end)
    end

    test "an else block whose clauses match specific errors" do
      """
      defmodule Example do
        def show(id, user) do
          with {:ok, post} <- fetch_post(id),
               :ok <- authorize(post, user) do
            {:ok, post}
          else
            {:error, :not_found} -> {:error, :post_not_found}
            {:error, :forbidden} -> {:error, :access_denied}
          end
        end
      end
      """
      |> to_source_file()
      |> run_check(@described_check)
      |> assert_issue()
    end

    test "the keyword syntax of with" do
      """
      defmodule Example do
        def run(a, b) do
          with {:ok, x} <- a.(),
               {:ok, y} <- b.(x),
               do: {:ok, y},
               else: ({:error, :a} -> :a_failed; {:error, :b} -> :b_failed)
        end
      end
      """
      |> to_source_file()
      |> run_check(@described_check)
      |> assert_issue()
    end

    test "each nested with on its own" do
      """
      defmodule Example do
        def run do
          with {:ok, a} <- first(),
               {:ok, b} <- second(a) do
            with {:ok, c} <- third(b),
                 {:ok, d} <- fourth(c) do
              d
            else
              {:error, :third} -> :third_failed
              {:error, :fourth} -> :fourth_failed
            end
          else
            {:error, :first} -> :first_failed
            {:error, :second} -> :second_failed
          end
        end
      end
      """
      |> to_source_file()
      |> run_check(@described_check)
      |> assert_issues(fn issues -> assert length(issues) == 2 end)
    end

    test "else blocks above a custom max_else_clauses" do
      """
      defmodule Example do
        def run do
          with {:ok, a} <- first(),
               {:ok, b} <- second(a) do
            b
          else
            {:error, :first} -> :first_failed
            {:error, :second} -> :second_failed
            :error -> :unknown
          end
        end
      end
      """
      |> to_source_file()
      |> run_check(@described_check, max_else_clauses: 2)
      |> assert_issue()
    end
  end

  describe "does not report" do
    test "a with without an else block" do
      """
      defmodule Example do
        def open_decoded_file(path) do
          with {:ok, encoded} <- file_read(path),
               {:ok, decoded} <- base_decode64(encoded) do
            {:ok, String.trim(decoded)}
          end
        end
      end
      """
      |> to_source_file()
      |> run_check(@described_check)
      |> refute_issues()
    end

    test "an else block with a single clause" do
      """
      defmodule Example do
        def open_decoded_file(path) do
          with {:ok, encoded} <- File.read(path),
               {:ok, decoded} <- Base.decode64(encoded) do
            decoded
          else
            {:error, _} -> :badfile
          end
        end
      end
      """
      |> to_source_file()
      |> run_check(@described_check)
      |> refute_issues()
    end

    test "a with with a single <- clause, which Credo's WithSingleClause already reports" do
      """
      defmodule Example do
        def create(attrs) do
          with ref = make_ref(),
               {:ok, user} <- User.create(ref, attrs) do
            user
          else
            {:error, :db_down} -> raise "DB is down!"
            {:error, reason} -> raise "error: \#{inspect(reason)}"
          end
        end
      end
      """
      |> to_source_file()
      |> run_check(@described_check)
      |> refute_issues()
    end

    test "else blocks within a custom max_else_clauses" do
      """
      defmodule Example do
        def run do
          with {:ok, a} <- first(),
               {:ok, b} <- second(a) do
            b
          else
            {:error, :first} -> :first_failed
            {:error, :second} -> :second_failed
          end
        end
      end
      """
      |> to_source_file()
      |> run_check(@described_check, max_else_clauses: 2)
      |> refute_issues()
    end

    test "a with built from unquote_splicing, whose clauses are unknown" do
      """
      defmodule Example do
        defmacro build(clauses) do
          quote do
            with unquote_splicing(clauses) do
              :ok
            else
              {:error, :a} -> :a
              {:error, :b} -> :b
            end
          end
        end
      end
      """
      |> to_source_file()
      |> run_check(@described_check)
      |> refute_issues()
    end

    test "variables and functions named with" do
      """
      defmodule Example do
        def with(value), do: value

        def run(with) do
          with = with + 1
          with
        end
      end
      """
      |> to_source_file()
      |> run_check(@described_check)
      |> refute_issues()
    end
  end
end
