defmodule Credo.Checks.Readability.ComplexElseClausesTest do
  use Credo.Test.Case

  @described_check Credo.Checks.Readability.ComplexElseClauses

  test "when there is no else clause, it should not raise issues" do
    """
    defmodule ComplexElseClauses do
      def open_decoded_file(path) do
        with {:ok, encoded} <- file_read(path),
          {:ok, value} <- base_decode64(encoded) do
          value
        end
      end
    end
    """
    |> to_source_file()
    |> run_check(@described_check)
    |> refute_issues()
  end

  test "when there is an else clause, it should not raise issues" do
    """
    defmodule ComplexElseClauses do
      def open_decoded_file(path) do
        with {:ok, encoded} <- file_read(path),
          {:ok, value} <- base_decode64(encoded) do
          value
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

  test "it should report a violation" do
    """
    defmodule ComplexElseClauses do
      def open_decoded_file(path) do
        with {:ok, encoded} <- File.read(path),
          {:ok, value} <- Base.decode64(encoded) do
        value
        else
          {:error, _} -> :badfile
          :error -> :badencoding
        end
      end
    end
    """
    |> to_source_file()
    |> run_check(@described_check)
    |> assert_issue()
  end
end
