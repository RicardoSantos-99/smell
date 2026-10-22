defmodule Smell do
  @moduledoc """
  Credo plugin with checks for the anti-patterns described in the official
  Elixir documentation.

  Add it to the `plugins` of your `.credo.exs`:

      %{configs: [%{name: "default", plugins: [{Smell, []}]}]}

  This enables every check in `checks/0`. If your `.credo.exs` declares an
  explicit `checks: %{enabled: [...]}` list, Credo only runs the checks in that
  list, so add Smell's checks to it instead:

      checks: %{
        enabled: [
          # ...your existing checks...
        ] ++ Enum.map(Smell.checks(), &{&1, []})
      }
  """

  import Credo.Plugin

  @checks [
    Smell.Check.Readability.ComplexElseClauses,
    Smell.Check.Warning.NamespaceTrespassing
  ]

  @default_config inspect(
                    %{
                      configs: [
                        %{name: "default", checks: %{extra: Enum.map(@checks, &{&1, []})}}
                      ]
                    },
                    limit: :infinity
                  )

  @doc false
  def init(exec) do
    register_default_config(exec, @default_config)
  end

  @doc false
  def default_config, do: @default_config

  @doc "Returns every check provided by Smell."
  def checks, do: @checks
end
