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

  The checks in `opt_in_checks/0` are not enabled by the plugin. Add the ones
  you want to the `checks` of your `.credo.exs`:

      checks: %{extra: [{Smell.Check.Design.UnsupervisedProcess, []}]}
  """

  import Credo.Plugin

  @checks [
    Smell.Check.Design.AppConfigInLibrary,
    Smell.Check.Design.UseInsteadOfImport,
    Smell.Check.Readability.ComplexElseClauses,
    Smell.Check.Warning.NamespaceTrespassing,
    Smell.Check.Warning.NonAssertivePatternMatching
  ]

  @opt_in_checks [
    Smell.Check.Design.BooleanObsession,
    Smell.Check.Design.UnsupervisedProcess
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

  @doc "Returns the checks that the plugin enables."
  def checks, do: @checks

  @doc "Returns the checks that the plugin does not enable, which you add yourself."
  def opt_in_checks, do: @opt_in_checks
end
