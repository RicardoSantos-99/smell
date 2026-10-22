defmodule Smell.Check.Helpers do
  @moduledoc false

  # `test/x_test.exs` and `apps/app/test/support/x.ex` are test files, while
  # `lib/app/test/helpers.ex` ships with the package.
  @doc false
  def test_file?(filename) do
    segments = Path.split(filename)

    case Enum.find_index(segments, &(&1 == "test")) do
      nil -> false
      index -> "lib" not in Enum.take(segments, index)
    end
  end

  # Project files such as mix.lock and mix.exs are read once per change instead
  # of once per source file. `owner` keeps the entries of each check apart.
  @doc false
  def cached_read(owner, path, default, read) do
    path = Path.expand(path)

    case File.stat(path) do
      {:ok, %File.Stat{mtime: mtime, size: size}} ->
        key = {owner, path, mtime, size}

        case :persistent_term.get(key, :undefined) do
          :undefined ->
            value = read.(path)
            :persistent_term.put(key, value)
            value

          value ->
            value
        end

      {:error, _reason} ->
        default
    end
  end
end
