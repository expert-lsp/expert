defmodule Project.DefaultArgs do
  def first_arg(x \\ 3, y) do
    x + y
  end

  def middle_arg(a, b \\ 3, c) do
    a + b + c
  end

  def last_arg(x, y \\ 3) do
    x + y
  end

  def options(a, opts \\ []) do
    a + Keyword.get(opts, :b, 0)
  end

  def multiple(a \\ 1, b \\ 2) do
    {a, b}
  end

  def struct_arg(a, b \\ %Project.Structs.User{}) do
    Map.put(b, :username, a)
  end

  def pattern_match_arg(%Project.Structs.User{} = user) do
    user
  end

  def reverse_pattern_match_arg(user = %Project.Structs.User{}) do
    user
  end
end
