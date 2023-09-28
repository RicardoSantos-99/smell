defmodule Smell do
  @config_file File.read!(".credo.exs")

  import Credo.Plugin

  def init(exec) do
    exec
    |> register_default_config(@config_file)
    |> prepend_task(:analyze, Credo.Checks.Readability.ComplexElseClauses)
  end
end
