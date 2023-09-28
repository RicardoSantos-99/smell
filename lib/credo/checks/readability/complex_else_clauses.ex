defmodule Credo.Checks.Readability.ComplexElseClauses do
  @moduledoc """
  This check identifies complex else blocks in with statements
  """
  use Credo.Check,
    base_priority: :higher,
    explanations: [
      check: """
        Problem: This code smell refers to with statements that flatten all its error clauses into a single complex else block.
        This situation is harmful to the code readability and maintainability
        because difficult to know from which clause the error value came.

        Example: An example of this code smell, as shown below, is a function open_decoded_file/1 that read a base 64 encoded string content from a file and returns a decoded binary string. This function uses a with statement that needs to handle two possible errors, all of which are concentrated in a single complex else block.
        The code in this example ...

            def open_decoded_file(path) do
              with {:ok, encoded} <- File.read(path),
                {:ok, value} <- Base.decode64(encoded) do
                value
              else
                {:error, _} -> :badfile
                :error -> :badencoding
              end
            end

        ... should be refactored to look like this:

            def open_decoded_file(path) do
              with {:ok, encoded} <- file_read(path),
                  {:ok, value} <- base_decode64(encoded) do
                value
              end
            end

            defp file_read(path) do
              case File.read(path) do
                {:ok, contents} -> {:ok, contents}
                {:error, _} -> :badfile
              end
            end

            defp base_decode64(contents) do
              case Base.decode64(contents) do
                {:ok, contents} -> {:ok, contents}
                :error -> :badencoding
              end
            end

        As shown above, in this situation,
        instead of concentrating all error handlings within a single complex else block,
        it is better to normalize the return types in specific private functions. In this way,
        due to its organization, the code will be cleaner and more readable.
      """
    ]

  @impl true
  def run(%SourceFile{} = source_file, params) do
    source_file
    |> Credo.Code.prewalk(&traverse(&1, &2, IssueMeta.for(source_file, params)))
  end

  defp traverse({:with, _meta, clauses} = ast, issues, issue_meta) do
    case List.last(clauses) |> Keyword.get(:else) do
      nil ->
        {ast, issues}

      simple_else when length(simple_else) == 1 ->
        {ast, issues}

      else_block ->
        {ast, add_issue(issues, issue_for(issue_meta, else_block))}
    end
  end

  defp traverse(ast, issues, _issue_meta), do: {ast, issues}

  def issue_for(issue_meta, else_block) do
    last_element =
      List.last(else_block)
      |> elem(1)

    format_issue(
      issue_meta,
      message: "Avoid complex else blocks",
      line_no: last_element[:line],
      column: last_element[:column],
      category: :readability
    )
  end

  defp add_issue(issues, issue), do: [issue | issues]
end
