defmodule SmellTest do
  use ExUnit.Case, async: true

  test "every listed check is a Credo check" do
    for check <- Smell.checks() do
      assert Credo.Check.defined?(check), "#{inspect(check)} is not a Credo check"
    end
  end

  test "the default config enables every check" do
    {config, _binding} = Code.eval_string(Smell.default_config())

    assert [%{name: "default", checks: %{extra: extra}}] = config.configs
    assert extra == Enum.map(Smell.checks(), &{&1, []})
  end
end
