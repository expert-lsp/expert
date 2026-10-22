defmodule Expert.CodeIntelligence.Completion.VariablesTest do
  use ExUnit.Case, async: true

  import Forge.Test.CodeSigil
  import Forge.Test.CursorSupport

  alias Expert.CodeIntelligence.Completion.Variables
  alias Forge.Ast

  defp in_scope(text) do
    {position, document} = pop_cursor(text, as: :document)

    document
    |> Ast.analyze()
    |> Variables.in_scope(position)
  end

  describe "in function bodies" do
    test "parameters are in scope" do
      assert [:a, :b] =
               in_scope(~q[
                 def f(a, %{key: b}) do
                   |
                 end
               ])
    end

    test "underscored variables are in scope and special forms are not" do
      assert [:_unused, :struct] =
               in_scope(~q[
                 def f(%__MODULE__{} = struct, _unused) do
                   |
                 end
               ])
    end

    test "earlier matches are in scope and later ones are not" do
      assert [:a, :b] =
               in_scope(~q[
                 def f(a) do
                   b = a
                   |
                   c = b
                 end
               ])
    end

    test "a statement's own match is not in scope at its start" do
      assert [:a] =
               in_scope(~q[
                 def f(a) do
                   |b = a
                 end
               ])
    end

    test "chained matches bind every pattern" do
      assert [:a, :b, :c] =
               in_scope(~q[
                 def f(a) do
                   %{} = b = c = a
                   |
                 end
               ])
    end

    test "a match in an argument is in scope in later arguments" do
      assert [:a, :value] =
               in_scope(~q[
                 def f(a) do
                   if value = a do
                     |
                   end
                 end
               ])
    end

    test "a match in an if subject or a call argument binds after it" do
      if_subject = ~q[
        def f(a) do
          if b = a do
            b
          end

          |
        end
      ]

      call_argument = ~q[
        def f(a) do
          send(self(), c = a)
          |
        end
      ]

      assert [:a, :b] = in_scope(if_subject)
      assert [:a, :c] = in_scope(call_argument)
    end

    test "a match in a keyword argument binds after it" do
      assert [:a, :b] =
               in_scope(~q[
                 def f(a) do
                   send(self(), key: b = a)
                   |
                 end
               ])
    end

    test "a match on the right of a short-circuiting operator or in a capture does not bind" do
      operator = ~q[
        def f(a) do
          a || (b = 1)
          |
        end
      ]

      capture = ~q[
        def f(a) do
          Enum.map(a, &(b = &1))
          |
        end
      ]

      assert [:a] = in_scope(operator)
      assert [:a] = in_scope(capture)
    end

    test "a match inside a function or a block does not bind after it" do
      assert [:a] =
               in_scope(~q[
                 def f(a) do
                   Enum.each(a, fn item -> b = item end)

                   if a do
                     c = a
                   end

                   |
                 end
               ])
    end

    test "a match is not in scope while its expression is typed" do
      for expression <- ["Foo.ba|", "Fo|o", "~s(a|b)", "(a + 1)|", "a.b|"],
          rest <- ["", "def g(x) do\n  x +\nend\n"] do
        assert [:a] =
                 in_scope("""
                 def f(a) do
                   fn -> x = #{expression} end
                 end
                 #{rest}\
                 """),
               expression <> " " <> rest
      end
    end

    test "pinned variables are not bound" do
      assert [:a, :b] =
               in_scope(~q[
                 def f(a) do
                   {^a, b} = a
                   |
                 end
               ])
    end

    test "the variable being typed is not in scope" do
      assert [:a, :b] =
               in_scope(~q[
                 def f(a) do
                   {b, curr|} = a
                 end
               ])
    end

    test "variables in binary patterns are bound" do
      assert [:a, :char, :rest] =
               in_scope(~q[
                 def f(a) do
                   <<char, rest::binary>> = a
                   |
                 end
               ])
    end
  end

  describe "in function heads" do
    test "a parameter sees the parameters before it" do
      assert [:a] =
               in_scope(~q[
                 def f(
                       a,
                       |b
                     ) do
                 end
               ])
    end

    test "a guard sees every parameter" do
      assert [:a, :b] =
               in_scope(~q[
                 def f(a, b)
                     when |is_atom(a) do
                 end
               ])
    end

    test "default arguments are parameters" do
      assert [:a, :b] =
               in_scope(~q[
                 def f(a, b \\\\ 1) do
                   |
                 end
               ])
    end

    test "a keyword body sees the parameters" do
      assert [:a] =
               in_scope(~q[
                 def f(a),
                   do: |a
               ])
    end
  end

  describe "in clauses" do
    test "a clause body sees its patterns and the enclosing variables" do
      assert [:a, :value] =
               in_scope(~q[
                 def f(a) do
                   case a do
                     {:ok, value} -> |
                     :error -> nil
                   end
                 end
               ])
    end

    test "a clause does not see the patterns of other clauses" do
      assert [:a] =
               in_scope(~q[
                 def f(a) do
                   case a do
                     {:ok, value} -> value
                     :error -> |
                   end
                 end
               ])
    end

    test "a clause pattern sees the enclosing variables for pins" do
      assert [:a, :b] =
               in_scope(~q[
                 def f(a, b) do
                   case a do
                     {^b, |} -> nil
                   end
                 end
               ])
    end

    test "a clause guard sees the clause patterns" do
      assert [:a, :value] =
               in_scope(~q[
                 def f(a) do
                   case a do
                     {:ok, value} when |is_atom(value) -> value
                   end
                 end
               ])
    end

    test "anonymous function clauses see their parameters" do
      assert [:a, :acc, :item] =
               in_scope(~q[
                 def f(a) do
                   Enum.reduce(a, 0, fn item, acc ->
                     |
                   end)
                 end
               ])
    end

    test "a function without parameters sees its body" do
      assert [:a, :b] =
               in_scope(~q[
                 def f(a) do
                   fn ->
                     b = a
                     |
                   end
                 end
               ])
    end

    test "a cond condition binds for its own clause" do
      assert [:a, :b] =
               in_scope(~q[
                 def f(a) do
                   cond do
                     b = a -> |
                   end
                 end
               ])
    end

    test "a cond condition does not bind for later clauses" do
      assert [:a] =
               in_scope(~q[
                 def f(a) do
                   cond do
                     b = a -> b
                     true -> |
                   end
                 end
               ])
    end

    test "a later anonymous function clause does not see an earlier one" do
      assert [:a, :second] =
               in_scope(~q[
                 def f(a) do
                   Enum.map(a, fn
                     {:first, first} -> first
                     {:second, second} -> |
                   end)
                 end
               ])
    end

    test "rescue, catch and else clauses see their patterns" do
      rescue_clause = ~q[
        def f(a) do
          try do
            a
          rescue
            error in RuntimeError -> |
          end
        end
      ]

      catch_clause = ~q[
        def f(a) do
          try do
            a
          catch
            kind, reason -> |
          end
        end
      ]

      else_clause = ~q[
        def f(a) do
          try do
            a
          else
            value -> |
          end
        end
      ]

      assert [:a, :error] = in_scope(rescue_clause)
      assert [:a, :kind, :reason] = in_scope(catch_clause)
      assert [:a, :value] = in_scope(else_clause)
    end

    test "receive clauses and after see the enclosing variables" do
      message = ~q[
        def f(a) do
          receive do
            {:message, body} -> |
          after
            a -> nil
          end
        end
      ]

      timeout = ~q[
        def f(a) do
          receive do
            {:message, body} -> body
          after
            a -> |
          end
        end
      ]

      assert [:a, :body] = in_scope(message)
      assert [:a] = in_scope(timeout)
    end

    test "an else branch does not see the do branch" do
      assert [:a] =
               in_scope(~q[
                 def f(a) do
                   if a do
                     b = a
                     b
                   else
                     |
                   end
                 end
               ])
    end

    test "a match? guard sees the pattern" do
      assert [:a, :value] =
               in_scope(~q[
                 def f(a) do
                   match?({:ok, value} when |is_atom(value), a)
                 end
               ])
    end
  end

  describe "in comprehensions" do
    test "a generator binds for later generators and the do block" do
      assert [:a, :x, :y] =
               in_scope(~q[
                 def f(a) do
                   for x <- a, y <- x do
                     |
                   end
                 end
               ])
    end

    test "a binary generator binds" do
      assert [:a, :char] =
               in_scope(~q[
                 def f(a) do
                   for <<char <- a>>, do: |
                 end
               ])
    end

    test "into and reduce do not see the generators" do
      into = ~q[
        def f(a) do
          for x <- a, into: |, do: x
        end
      ]

      reduce = ~q[
        def f(a) do
          for x <- a, reduce: 0 do
            acc -> |
          end
        end
      ]

      assert [:a] = in_scope(into)
      assert [:a, :acc, :x] = in_scope(reduce)
    end

    test "a list argument is not taken for options" do
      assert [:a, :x] =
               in_scope(~q[
                 def f(a) do
                   for x <- a, x in ~w(a b)a, do: |
                 end
               ])
    end

    test "a generator does not bind before it" do
      assert [:a] =
               in_scope(~q[
                 def f(a) do
                   for |x <- a, do: x
                 end
               ])
    end

    test "with binds for the do block but not for else" do
      do_block = ~q[
        def f(a) do
          with {:ok, b} <- a do
            |
          else
            _ -> nil
          end
        end
      ]

      else_block = ~q[
        def f(a) do
          with {:ok, b} <- a do
            b
          else
            _ -> |
          end
        end
      ]

      assert [:a, :b] = in_scope(do_block)
      assert [:a] = in_scope(else_block)
    end
  end

  describe "scope boundaries" do
    test "module-level variables are not in scope in a definition" do
      assert [] =
               in_scope(~q[
                 defmodule Example do
                   value = 1

                   def f do
                     |
                   end
                 end
               ])
    end

    test "variables around a generated definition are in scope inside unquote" do
      assert [:name] =
               in_scope(~q[
                 defmodule Example do
                   for name <- ~w(a b)a do
                     def unquote(na|)(), do: nil
                   end
                 end
               ])
    end

    test "variables around a module are in scope in its body" do
      assert [:key] =
               in_scope(~q[
                 for key <- ~w(a b)a do
                   defmodule Example do
                     @key |
                   end
                 end
               ])
    end

    test "a nested module's definitions do not see the enclosing definition" do
      assert [:b] =
               in_scope(~q[
                 defmodule Outer do
                   def f(a), do: a

                   defmodule Inner do
                     def g(b) do
                       |
                     end
                   end
                 end
               ])
    end

    test "unquote in a macro's quote sees the macro's variables" do
      assert [:arg] =
               in_scope(~q[
                 defmacro m(arg) do
                   quote do
                     unquote(ar|)
                   end
                 end
               ])
    end

    test "an empty unquote sees the variables around the quote" do
      plain = ~q[
        def f(a) do
          quote do
            unquote(|)
          end
        end
      ]

      in_definition = ~q[
        defmacro m(a) do
          quote do
            def g(b) do
              unquote(|)
            end
          end
        end
      ]

      assert [:a] = in_scope(plain)
      assert [:a] = in_scope(in_definition)
    end

    test "unquote in a definition generated by a quote sees the quote's variables" do
      assert [:name, :opts] =
               in_scope(~q[
                 defmacro __using__(opts) do
                   name = Keyword.fetch!(opts, :name)

                   quote do
                     def unquote(na|)(), do: nil
                   end
                 end
               ])
    end

    test "unquote_splicing in a head sees the variables around the definition" do
      assert [:args] =
               in_scope(~q[
                 defmodule Example do
                   args = Enum.to_list(1..2)
                   def f(unquote_splicing(ar|)), do: nil
                 end
               ])
    end

    test "a quote body does not see the variables around it" do
      assert [] =
               in_scope(~q[
                 defmacro m(arg) do
                   quote do
                     |
                   end
                 end
               ])
    end

    test "a quote body sees its bound variables" do
      assert [:name] =
               in_scope(~q"""
               defmacro m(arg) do
                 quote bind_quoted: [name: arg] do
                   |
                 end
               end
               """)
    end

    test "typespecs are not read as code" do
      assert [] =
               in_scope(~q[
                 defmodule Example do
                   @spec f((integer -> |)) :: :ok
                 end
               ])
    end

    test "ExUnit test and setup contexts are in scope" do
      test_block = ~q[
        defmodule ExampleTest do
          test "x", %{conn: conn} do
            |
          end
        end
      ]

      setup_block = ~q[
        defmodule ExampleTest do
          setup %{conn: conn} do
            |
          end
        end
      ]

      assert [:conn] = in_scope(test_block)
      assert [:conn] = in_scope(setup_block)
    end

    test "a position before a definition sees nothing from it" do
      assert [] =
               in_scope(~q[
                 defmodule Example do
                   |
                   def f(a), do: a
                 end
               ])
    end
  end

  describe "in incomplete code" do
    test "an unfinished clause body sees its patterns" do
      assert [:a, :value] =
               in_scope(~q[
                 def f(a) do
                   case a do
                     {:ok, value} -> |
               ])
    end

    test "an unfinished anonymous function sees its parameters" do
      assert [:a, :item] =
               in_scope(~q[
                 def f(a) do
                   Enum.map(a, fn item -> |
               ])
    end

    test "an earlier clause sees its patterns while a later one is unfinished" do
      assert [:a, :value] =
               in_scope(~q[
                 def f(a) do
                   case a do
                     {:ok, value} -> val|
                     {:error, reason} ->
               ])
    end

    test "an unfinished head sees the parameters before the cursor" do
      assert [:a] =
               in_scope(~q[
                 def f(a, |
               ])
    end

    test "an error elsewhere in the document does not open closed code" do
      assert [:a] =
               in_scope(~q[
                 def f(a) do
                   case a do
                     value ->
                   end

                   |
                 end

                 def g(x) do
                   x +
                 end
               ])
    end

    test "an unfinished condition sees the enclosing variables" do
      assert [:env] =
               in_scope(~q"""
               def f(env) do
                 cond do
                   not g(en|
                     []

                   h(env) ->
                     :ok
                 end
               end
               """)
    end

    test "an unclosed pattern in a clause head sees the enclosing variables" do
      assert [:a] =
               in_scope(~q[
                 def f(a) do
                   case a do
                     {:unquoted|
                   end
                 end
               ])
    end

    test "an unfinished with sees its earlier generators" do
      assert [:a, :b] =
               in_scope(~q[
                 def f(a) do
                   with {:ok, b} <- a,
                        |
               ])
    end
  end
end
