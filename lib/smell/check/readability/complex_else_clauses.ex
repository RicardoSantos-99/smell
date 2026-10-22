defmodule Smell.Check.Readability.ComplexElseClauses do
  use Credo.Check,
    base_priority: :higher,
    tags: [:anti_pattern],
    param_defaults: [max_else_clauses: 1],
    docs_uri: "https://hexdocs.pm/elixir/code-anti-patterns.html#complex-else-clauses-in-with",
    explanations: [
      check: """
      Avoid `with` expressions that flatten the error handling of all their
      clauses into a single complex `else` block.

      This is the "Complex `else` clauses in `with`" anti-pattern from the
      official Elixir documentation. When every failure is handled in one
      `else`, it is hard to know from which `<-` clause each error value came,
      and the more clauses there are, the more likely it is that unrelated
      failures overlap.

          def open_decoded_file(path) do
            with {:ok, encoded} <- File.read(path),
                 {:ok, decoded} <- Base.decode64(encoded) do
              {:ok, String.trim(decoded)}
            else
              {:error, _} -> {:error, :badfile}
              :error -> {:error, :badencoding}
            end
          end

      Normalize the return values in private functions instead, so `with`
      focuses on the success case and each error is handled close to where it
      happens:

          def open_decoded_file(path) do
            with {:ok, encoded} <- file_read(path),
                 {:ok, decoded} <- base_decode64(encoded) do
              {:ok, String.trim(decoded)}
            end
          end

          defp file_read(path) do
            case File.read(path) do
              {:ok, contents} -> {:ok, contents}
              {:error, _} -> {:error, :badfile}
            end
          end

          defp base_decode64(contents) do
            case Base.decode64(contents) do
              {:ok, decoded} -> {:ok, decoded}
              :error -> {:error, :badencoding}
            end
          end

      Only `with` expressions with two or more `<-` clauses are reported. With a
      single `<-` clause the source of the error is unambiguous, and Credo's
      `Credo.Check.Readability.WithSingleClause` already suggests a `case`.
      """,
      params: [
        max_else_clauses: "The maximum number of clauses allowed in the `else` block."
      ]
    ]

  @doc false
  @impl true
  def run(%SourceFile{} = source_file, params) do
    issue_meta = IssueMeta.for(source_file, params)
    max_else_clauses = Params.get(params, :max_else_clauses, __MODULE__)

    Credo.Code.prewalk(source_file, &traverse(&1, &2, issue_meta, max_else_clauses))
  end

  defp traverse({:with, meta, [_ | _] = args} = ast, issues, issue_meta, max_else_clauses) do
    with {:ok, clauses, else_clauses} <- split_with(args),
         false <- Enum.any?(clauses, &unquote_splicing?/1),
         pattern_clauses when pattern_clauses >= 2 <- Enum.count(clauses, &pattern_clause?/1),
         else_count when else_count > max_else_clauses <- length(else_clauses) do
      {ast, [issue_for(issue_meta, meta, else_count, pattern_clauses) | issues]}
    else
      _ -> {ast, issues}
    end
  end

  defp traverse(ast, issues, _issue_meta, _max_else_clauses), do: {ast, issues}

  # A real `with` ends with a keyword list holding the `:do` block. Anything
  # else named `with` (a variable, a function head) is not a `with` expression.
  defp split_with(args) do
    {clauses, [blocks]} = Enum.split(args, -1)

    with true <- Keyword.keyword?(blocks) and Keyword.has_key?(blocks, :do),
         else_block when is_list(else_block) <- Keyword.get(blocks, :else) do
      {:ok, clauses, Enum.filter(else_block, &match?({:->, _, _}, &1))}
    else
      _ -> :error
    end
  end

  defp pattern_clause?({:<-, _, _}), do: true
  defp pattern_clause?(_), do: false

  defp unquote_splicing?({:unquote_splicing, _, _}), do: true
  defp unquote_splicing?(_), do: false

  defp issue_for(issue_meta, meta, else_count, pattern_clauses) do
    format_issue(
      issue_meta,
      message:
        "Avoid complex `else` blocks in `with`: #{else_count} `else` clauses handle errors " <>
          "from #{pattern_clauses} `<-` clauses. Normalize the errors in private functions instead.",
      trigger: "with",
      line_no: meta[:line],
      column: meta[:column]
    )
  end
end
