defmodule Expert.Search.Indexer.Extractors.VariableTest do
  use Expert.Test.ExtractorCase

  alias Expert.Search.Indexer.Extractors

  def index_references(source) do
    do_index(source, fn entry -> entry.type == :variable and entry.subtype == :reference end, [
      Extractors.Variable
    ])
  end

  def index_definitions(source) do
    do_index(source, fn entry -> entry.type == :variable and entry.subtype == :definition end, [
      Extractors.Variable
    ])
  end

  def index(source) do
    do_index(source, &(&1.type == :variable), [Extractors.Variable])
  end

  def assert_definition(entry, variable_name) do
    assert entry.type == :variable
    assert entry.subtype == :definition
    assert entry.subject == variable_name
  end

  def assert_reference(entry, variable_name) do
    assert entry.type == :variable
    assert entry.subtype == :reference
    assert entry.subject == variable_name
  end

  for def_type <- [:def, :defp, :defmacro, :defmacrop] do
    describe "variable definitions in #{def_type} parameters are extracted" do
      test "in a plain parameter" do
        {:ok, [param], doc} =
          ~q[
          #{unquote(def_type)} my_fun(var) do
          end
          ]
          |> index_definitions()

        assert_definition(param, :var)
        assert decorate(doc, param.range) =~ "#{unquote(def_type)} my_fun(«var»)"
      end

      test "in a struct value" do
        {:ok, [param], doc} =
          ~q[
        #{unquote(def_type)} my_fun(%Pattern{foo: var}) do
        end
        ]
          |> index_definitions()

        assert_definition(param, :var)
        assert decorate(doc, param.range) =~ "#{unquote(def_type)} my_fun(%Pattern{foo: «var»})"
      end

      test "on both sides of a pattern match" do
        {:ok, [var_1, var_2], doc} =
          ~q[
        #{unquote(def_type)} my_fun(%Pattern{foo: var} = var_2) do
        end
        ]
          |> index_definitions()

        assert_definition(var_1, :var)

        assert decorate(doc, var_1.range) =~
                 "#{unquote(def_type)} my_fun(%Pattern{foo: «var»} = var_2)"

        assert_definition(var_2, :var_2)

        assert decorate(doc, var_2.range) =~
                 "#{unquote(def_type)} my_fun(%Pattern{foo: var} = «var_2»)"
      end

      test "in a struct module" do
        {:ok, [var_1], doc} =
          ~q[
        #{unquote(def_type)} my_fun(%my_module{}) do
        end
        ]
          |> index_definitions()

        assert_definition(var_1, :my_module)
        assert decorate(doc, var_1.range) =~ "#{unquote(def_type)} my_fun(%«my_module»{})"
      end

      test "in a bitstrings" do
        {:ok, [var], doc} =
          ~q[
            #{unquote(def_type)} my_fun(<<foo::binary-size(3)>>) do
            end
          ]
          |> index_definitions()

        assert_definition(var, :foo)

        assert decorate(doc, var.range) =~
                 "#{unquote(def_type)} my_fun(<<«foo»::binary-size(3)>>) do"
      end

      test "in list elements" do
        {:ok, [var_1, var_2], doc} =
          ~q{
        #{unquote(def_type)} my_fun([var_1, var_2]) do
        end
        }
          |> index_definitions()

        assert_definition(var_1, :var_1)
        assert decorate(doc, var_1.range) =~ "#{unquote(def_type)} my_fun([«var_1», var_2])"

        assert_definition(var_2, :var_2)
        assert decorate(doc, var_2.range) =~ "#{unquote(def_type)} my_fun([var_1, «var_2»])"
      end

      test "in the tail of a list" do
        {:ok, [tail], doc} =
          ~q{
        #{unquote(def_type)} my_fun([_ | acc]) do
        end
        }
          |> index_definitions()

        assert_definition(tail, :acc)
        assert decorate(doc, tail.range) =~ "#{unquote(def_type)} my_fun([_ | «acc»])"
      end

      test "unless it is an alias" do
        {:ok, [], _} =
          ~q[
            #{unquote(def_type)} my_fun(%MyStruct{}) do
            end
          ]
          |> index_definitions()
      end

      test "unless it begins with an underscore" do
        {:ok, [], _} =
          ~q[
            #{unquote(def_type)} my_fun(_unused) do
            end
          ]
          |> index_definitions()

        {:ok, [], _} =
          ~q[
            #{unquote(def_type)} my_fun(_) do
            end
          ]
          |> index_definitions()
      end
    end

    describe "variable definitions in #{def_type} that contain references are extracted" do
      test "when passed through" do
        {:ok, [def, ref], doc} =
          ~q[
            #{unquote(def_type)} my_fun(var) do
              var
            end
          ]
          |> index()

        assert_definition(def, :var)
        assert_reference(ref, :var)

        assert decorate(doc, def.range) =~ "#{unquote(def_type)} my_fun(«var») do"
        assert decorate(doc, ref.range) =~ "  «var»"
      end

      test "when wrapped in a list" do
        {:ok, [def, ref], doc} =
          ~q{
            #{unquote(def_type)} my_fun([var]) do
              [var]
            end
          }
          |> index()

        assert_definition(def, :var)
        assert_reference(ref, :var)

        assert decorate(doc, def.range) =~ "#{unquote(def_type)} my_fun([«var»]) do"
        assert decorate(doc, ref.range) =~ "  [«var»]"
      end

      test "when it's a map value" do
        {:ok, [def, ref], doc} =
          ~q[
            #{unquote(def_type)} my_fun(%{key: var}) do
              %{key: var}
            end
          ]
          |> index()

        assert_definition(def, :var)
        assert_reference(ref, :var)

        assert decorate(doc, def.range) =~ "#{unquote(def_type)} my_fun(%{key: «var»}) do"
        assert decorate(doc, ref.range) =~ "  %{key: «var»}"
      end

      test "when it's a struct module" do
        {:ok, [def, ref], doc} =
          ~q[
            #{unquote(def_type)} my_fun(%{key: var}) do
              %{key: var}
            end
          ]
          |> index()

        assert_definition(def, :var)
        assert_reference(ref, :var)

        assert decorate(doc, def.range) =~ "#{unquote(def_type)} my_fun(%{key: «var»}) do"
        assert decorate(doc, ref.range) =~ "  %{key: «var»}"
      end

      test "when it's a tuple entry " do
        {:ok, [def, ref], doc} =
          ~q[
            #{unquote(def_type)} my_fun({var}) do
              {var}
            end
          ]
          |> index()

        assert_definition(def, :var)
        assert_reference(ref, :var)

        assert decorate(doc, def.range) =~ "#{unquote(def_type)} my_fun({«var»}) do"
        assert decorate(doc, ref.range) =~ "  {«var»}"
      end

      test "when it utilizes a pin " do
        {:ok, [first_def, second_def, first_pin, other_def, second_ref, other_ref], doc} =
          ~q"
            #{unquote(def_type)} my_fun({first, second}) do
              [^first, other] = second
              other
            end
          "
          |> index()

        assert_definition(first_def, :first)

        assert decorate(doc, first_def.range) =~
                 "#{unquote(def_type)} my_fun({«first», second}) do"

        assert_definition(second_def, :second)

        assert decorate(doc, second_def.range) =~
                 "#{unquote(def_type)} my_fun({first, «second»}) do"

        assert_reference(first_pin, :first)
        assert decorate(doc, first_pin.range) =~ "  [^«first», other]"

        assert_definition(other_def, :other)
        assert decorate(doc, other_def.range) =~ "  [^first, «other»]"

        assert_reference(second_ref, :second)
        assert decorate(doc, second_ref.range) =~ "  [^first, other] = «second»"

        assert_reference(other_ref, :other)
        assert decorate(doc, other_ref.range) =~ " «other»"
      end
    end
  end

  describe "variable definitions in anonymous function parameters are extracted" do
    test "when definition on the right side of the equals" do
      {:ok, [ref], doc} =
        ~q[
          fn 1 = a -> a end
        ]
        |> index_references()

      assert decorate(doc, ref.range) =~ "fn 1 = a -> «a»"
    end

    test "in a plain parameter" do
      {:ok, [param], doc} =
        ~q[
         fn var ->
          nil
         end
        ]
        |> index_definitions()

      assert_definition(param, :var)
      assert decorate(doc, param.range) =~ "fn «var» ->"
    end

    test "in a struct's values" do
      {:ok, [param], doc} =
        ~q[
        fn %Pattern{foo: var} ->
          nil
        end
        ]
        |> index_definitions()

      assert_definition(param, :var)
      assert decorate(doc, param.range) =~ "fn %Pattern{foo: «var»} ->"
    end

    test "when they're pinned" do
      {:ok, [param], doc} =
        ~q[
        fn ^pinned ->
          nil
        end
        ]
        |> index_references()

      assert_reference(param, :pinned)
      assert decorate(doc, param.range) =~ "fn ^«pinned» ->"
    end

    test "on both sides of a pattern match" do
      {:ok, [var_1, var_2], doc} =
        ~q[
        fn %Pattern{foo: var} = var_2 ->
          nil
        end
        ]
        |> index_definitions()

      assert_definition(var_1, :var)
      assert decorate(doc, var_1.range) =~ "fn %Pattern{foo: «var»} = var_2 ->"

      assert_definition(var_2, :var_2)
      assert decorate(doc, var_2.range) =~ "fn %Pattern{foo: var} = «var_2» ->"
    end

    test "in a struct module" do
      {:ok, [var_1], doc} =
        ~q[
        fn %my_module{} ->
          nil
        end
        ]
        |> index_definitions()

      assert_definition(var_1, :my_module)
      assert decorate(doc, var_1.range) =~ "fn %«my_module»{} ->"
    end

    test "in list elements" do
      {:ok, [var_1, var_2], doc} =
        ~q{
        fn [var_1, var_2] ->
          nil
        end
        }
        |> index_definitions()

      assert_definition(var_1, :var_1)
      assert decorate(doc, var_1.range) =~ "fn [«var_1», var_2] ->"

      assert_definition(var_2, :var_2)
      assert decorate(doc, var_2.range) =~ "fn [var_1, «var_2»] ->"
    end

    test "in the tail of a list" do
      {:ok, [tail], doc} =
        ~q{
         fn [_ | acc] ->
          nil
          end
        }
        |> index_definitions()

      assert_definition(tail, :acc)
      assert decorate(doc, tail.range) =~ "fn [_ | «acc»] ->"
    end

    test "unless it is an alias" do
      {:ok, [], _} =
        ~q[
        fn %MyStruct{} ->
          nil
        end
        ]
        |> index_definitions()
    end

    test "unless it starts with an underscore" do
      {:ok, [], _} =
        ~q[
        fn _unused ->
          nil
        end
        ]
        |> index_definitions()

      {:ok, [], _} =
        ~q[
        fn _ ->
          nil
        end
        ]
        |> index_definitions()
    end
  end

  describe "variable definitions in code are extracted" do
    test "from full pattern matches" do
      {:ok, [var], doc} = index_definitions(~q[var = 38])

      assert_definition(var, :var)
      assert decorate(doc, var.range) =~ "«var» = 38"
    end

    test "from tuples elements" do
      {:ok, [first, second], doc} = index_definitions(~q({first, second} = foo))

      assert_definition(first, :first)
      assert decorate(doc, first.range) =~ "{«first», second} ="

      assert_definition(second, :second)
      assert decorate(doc, second.range) =~ "{first, «second»} ="
    end

    test "from list elements" do
      {:ok, [first, second], doc} = index_definitions(~q([first, second] = foo))

      assert_definition(first, :first)
      assert decorate(doc, first.range) =~ "[«first», second] ="

      assert_definition(second, :second)
      assert decorate(doc, second.range) =~ "[first, «second»] ="
    end

    test "from  map values" do
      {:ok, [value], doc} = index_definitions(~q(%{key: value} = whatever))

      assert_definition(value, :value)
      assert decorate(doc, value.range) =~ "%{key: «value»} = whatever"
    end

    test "from struct values" do
      {:ok, [value], doc} = index_definitions(~q(%MyStruct{key: value} = whatever))

      assert_definition(value, :value)
      assert decorate(doc, value.range) =~ "%MyStruct{key: «value»} = whatever"
    end

    test "from struct modules" do
      {:ok, [module], doc} = index_definitions(~q(%struct_module{} = whatever))

      assert_definition(module, :struct_module)
      assert decorate(doc, module.range) =~ "%«struct_module»{} = whatever"
    end

    test "in an else block in a with" do
      {:ok, [value], doc} =
        ~q[
          with true <- true do
            :bad
          else var ->
            :ok
          end
        ]
        |> index_definitions()

      assert_definition(value, :var)
      assert decorate(doc, value.range) =~ "else «var» ->"
    end

    test "from comprehensions" do
      {:ok, [var, thing, field_1, field_2], doc} =
        ~q[
          for var <- things,
              {:ok, thing} = var,
              {:record, field_1, field_2} <- thing do
          end
        ]
        |> index_definitions()

      assert_definition(var, :var)
      assert decorate(doc, var.range) =~ "for «var» <- things,"

      assert_definition(thing, :thing)
      assert decorate(doc, thing.range) =~ "{:ok, «thing»} = var,"

      assert_definition(field_1, :field_1)
      assert decorate(doc, field_1.range) =~ "{:record, «field_1», field_2} <- thing do"

      assert_definition(field_2, :field_2)
      assert decorate(doc, field_2.range) =~ "{:record, field_1, «field_2»} <- thing do"
    end

    test "in an else block in a try" do
      {:ok, [value], doc} =
        ~q[
          try  do
            :ok
          else failure ->
            failure
          end
        ]
        |> index_definitions()

      assert_definition(value, :failure)
      assert decorate(doc, value.range) =~ "else «failure» ->"
    end

    test "in a catch block in a try" do
      {:ok, [value], doc} =
        ~q[
          try  do
            :ok
           catch thrown ->
             thrown
          end
        ]
        |> index_definitions()

      assert_definition(value, :thrown)
      assert decorate(doc, value.range) =~ "catch «thrown» ->"
    end

    test "in a rescue block in a try" do
      {:ok, [value], doc} =
        ~q[
          try  do
            :ok
          rescue ex ->
             ex
          end
        ]
        |> index_definitions()

      assert_definition(value, :ex)
      assert decorate(doc, value.range) =~ "rescue «ex» ->"
    end

    test "in a rescue block in a try using in" do
      {:ok, [value], doc} =
        ~q[
          try  do
            :ok
          rescue ex in RuntimeError ->
            ex
          end
        ]
        |> index_definitions()

      assert_definition(value, :ex)
      assert decorate(doc, value.range) =~ "rescue «ex» in RuntimeError ->"
    end

    test "from complex, nested mappings" do
      {:ok, [module, list_elem, tuple_first, tuple_second], doc} =
        index_definitions(
          ~q(%struct_module{key: [list_elem, {tuple_first, tuple_second}]} = whatever)
        )

      assert_definition(module, :struct_module)

      assert decorate(doc, module.range) =~
               "%«struct_module»{key: [list_elem, {tuple_first, tuple_second}]} = whatever"

      assert_definition(list_elem, :list_elem)

      assert decorate(doc, list_elem.range) =~
               "%struct_module{key: [«list_elem», {tuple_first, tuple_second}]} = whatever"

      assert_definition(tuple_first, :tuple_first)

      assert decorate(doc, tuple_first.range) =~
               "%struct_module{key: [list_elem, {«tuple_first», tuple_second}]} = whatever"

      assert_definition(tuple_second, :tuple_second)

      assert decorate(doc, tuple_second.range) =~
               "%struct_module{key: [list_elem, {tuple_first, «tuple_second»}]} = whatever"
    end

    test "from test arguments" do
      {:ok, [test_def], doc} =
        ~q[
        defmodule TestCase do
          use ExUnit.Case
          test "my test", %{var: var} do
            var
          end
        end
        ]
        |> index_definitions()

      assert_definition(test_def, :var)
      assert decorate(doc, test_def.range) =~ "%{var: «var»} do"
    end
  end

  describe "variable references are extracted" do
    test "when by themselves" do
      assert {:ok, [ref], doc} = index_references(~q[variable])

      assert_reference(ref, :variable)
      assert decorate(doc, ref.range) =~ "«variable»"
    end

    test "from pinned variables" do
      {:ok, [ref], doc} = index_references("^pinned = 3")

      assert_reference(ref, :pinned)
      assert decorate(doc, ref.range) =~ "^«pinned» = 3"
    end

    test "from pinned variables in a function head" do
      {:ok, [ref], doc} =
        ~q{
          fn [^pinned] ->
            nil
          end
        }
        |> index()

      assert_reference(ref, :pinned)
      assert decorate(doc, ref.range) =~ "fn [^«pinned»] ->"
    end

    test "on the left side of operators" do
      assert {:ok, [ref], doc} = index_references(~q[x + 3])

      assert_reference(ref, :x)
      assert decorate(doc, ref.range) =~ "«x» + 3"
    end

    test "on the right side of operators" do
      assert {:ok, [ref], doc} = index_references(~q[3 + x])

      assert_reference(ref, :x)
      assert decorate(doc, ref.range) =~ "3 + «x»"
    end

    test "on the right of pattern matches" do
      assert {:ok, [ref], doc} = index_references(~q[x = other_variable])

      assert_reference(ref, :other_variable)
      assert decorate(doc, ref.range) =~ "x = «other_variable»"
    end

    test "on the right side of pattern matches with dot notation" do
      assert {:ok, [ref], doc} = index_references(~q[x = foo.bar.baz])

      assert_reference(ref, :foo)
      assert decorate(doc, ref.range) =~ "x = «foo».bar.baz"
    end

    test "on the right side of a pattern match in a function call" do
      assert {:ok, [ref], doc} = index_references(~q[_ = foo(bar)])

      assert_reference(ref, :bar)
      assert decorate(doc, ref.range) =~ "_ = foo(«bar»)"
    end

    test "on the left of pattern matches via a pin" do
      assert {:ok, [ref], doc} = index_references(~q[^pin = 49])

      assert_reference(ref, :pin)
      assert decorate(doc, ref.range) =~ "^«pin» = 49"
    end

    test "from function call arguments" do
      assert {:ok, [ref], doc} = index_references(~q[pow(x, 3)])

      assert_reference(ref, :x)
      assert decorate(doc, ref.range) =~ "pow(«x», 3)"
    end

    test "when using access syntax" do
      assert {:ok, [ref], doc} = index_references(~q{3 = foo[:bar]})

      assert_reference(ref, :foo)
      assert decorate(doc, ref.range) =~ "3 = «foo»[:bar]"
    end

    test "when inside brackets" do
      assert {:ok, [ref, access_ref], doc} = index_references(~q{3 = foo[bar]})

      assert_reference(ref, :foo)
      assert decorate(doc, ref.range) =~ "3 = «foo»[bar]"

      assert_reference(access_ref, :bar)
      assert decorate(doc, access_ref.range) =~ "3 = foo[«bar»]"
    end

    test "inside string interpolations" do
      quoted =
        quote file: "foo.ex", line: 1 do
          foo = 3
          "#{foo}"
        end

      assert {:ok, [ref], doc} = index_references(quoted)

      assert_reference(ref, :foo)
      assert decorate(doc, ref.range) =~ ~S["#{«foo»}"]
    end

    test "inside string interpolations that have a statement" do
      quoted =
        quote file: "foo.ex", line: 1 do
          foo = 3
          "#{foo + 3}"
        end

      assert {:ok, [ref], doc} = index_references(quoted)

      assert_reference(ref, :foo)
      assert decorate(doc, ref.range) =~ ~S["#{«foo» + 3}"]
    end

    test "inside string interpolations that have a literal prefix" do
      quoted =
        quote file: "foo.ex", line: 1 do
          foo = 3
          "prefix #{foo}"
        end

      assert {:ok, [ref], doc} = index_references(quoted)

      assert_reference(ref, :foo)
      assert decorate(doc, ref.range) =~ ~S["prefix #{«foo»}"]
    end

    test "inside string interpolations that have a literal suffix" do
      quoted =
        quote file: "foo.ex", line: 1 do
          foo = 3
          "#{foo} suffix"
        end

      assert {:ok, [ref], doc} = index_references(quoted)

      assert_reference(ref, :foo)
      assert decorate(doc, ref.range) =~ ~S["#{«foo»} suffix"]
    end

    test "inside string interpolations that have a literal prefix and suffix" do
      quoted =
        quote file: "foo.ex", line: 1 do
          foo = 3
          "prefix #{foo} suffix"
        end

      assert {:ok, [ref], doc} = index_references(quoted)

      assert_reference(ref, :foo)
      assert decorate(doc, ref.range) =~ ~S["prefix #{«foo»} suffix"]
    end

    test "when inside a rescue block in a try" do
      {:ok, [ref], doc} =
        ~q[
          try  do
            :ok
          rescue e in Something ->
            e
          end
        ]
        |> index_references()

      assert_reference(ref, :e)
      assert decorate(doc, ref.range) =~ " «e»"
    end

    test "when inside a catch block in a try" do
      {:ok, [ref], doc} =
        ~q[
          try  do
            :ok
           catch thrown ->
            thrown
          end
        ]
        |> index_references()

      assert_reference(ref, :thrown)
      assert decorate(doc, ref.range) =~ " «thrown»"
    end

    test "when inside an after block in a try" do
      {:ok, [ref], doc} =
        ~q[
          try  do
            :ok
           after ->
            x
          end
        ]
        |> index_references()

      assert_reference(ref, :x)
      assert decorate(doc, ref.range) =~ " «x»"
    end

    test "when inside an else block in a with" do
      {:ok, [ref], doc} =
        ~q[
          with :ok <- call() do
          else other ->
           other
          end
        ]
        |> index_references()

      assert_reference(ref, :other)
      assert decorate(doc, ref.range) =~ " «other»"
    end

    test "when in the tail of a list" do
      assert {:ok, [ref], doc} = index_references(~q{[3 | acc]})

      assert_reference(ref, :acc)
      assert decorate(doc, ref.range) =~ "[3 | «acc»]"
    end

    test "in the body of an anonymous function" do
      {:ok, [ref], doc} =
        ~q[
        fn %Pattern{foo: var} ->
          var
        end
        ]
        |> index_references()

      assert_reference(ref, :var)
      assert decorate(doc, ref.range) =~ "  «var»"
    end

    test "when unquote is used in a function definition" do
      {:ok, [ref], doc} =
        ~q[
        def my_fun(unquote(other_var)) do
        end
        ]
        |> index_references()

      assert_reference(ref, :other_var)
      assert decorate(doc, ref.range) =~ "def my_fun(unquote(«other_var»)) do"
    end

    test "unless it begins with underscore" do
      assert {:ok, [], _} = index_references("_")
      assert {:ok, [], _} = index_references("_unused")
      assert {:ok, [], _} = index_references("_unused = 3")
      assert {:ok, [], _} = index_references("_unused = foo()")
    end
  end

  describe "variable and references are extracted" do
    test "in a multiple match" do
      {:ok, [foo_def, param_def, bar_def, other_ref], doc} =
        ~q[
          foo = param = bar = other
        ]
        |> index()

      assert_definition(foo_def, :foo)
      assert decorate(doc, foo_def.range) =~ "«foo» = param = bar = other"

      assert_definition(param_def, :param)
      assert decorate(doc, param_def.range) =~ "foo = «param» = bar = other"

      assert_definition(bar_def, :bar)
      assert decorate(doc, bar_def.range) =~ "foo = param = «bar» = other"

      assert_reference(other_ref, :other)
      assert decorate(doc, other_ref.range) =~ "foo = param = bar = «other»"
    end

    test "in an anonymous function" do
      {:ok, [pin_param, var_param, first_def, pin_pin, var_ref, first_ref], doc} =
        ~q{
          fn pin, var ->
            [first, ^pin] = var
            first
          end
        }
        |> index()

      assert_definition(pin_param, :pin)
      assert decorate(doc, pin_param.range) =~ "fn «pin», var ->"

      assert_definition(var_param, :var)
      assert decorate(doc, var_param.range) =~ "fn pin, «var» ->"

      assert_definition(first_def, :first)
      assert decorate(doc, first_def.range) =~ "  [«first», ^pin] = var"

      assert_reference(pin_pin, :pin)
      assert decorate(doc, pin_pin.range) =~ "  [first, ^«pin»] = var"

      assert_reference(var_ref, :var)
      assert decorate(doc, var_ref.range) =~ "  [first, ^pin] = «var»"

      assert_reference(first_ref, :first)
      assert decorate(doc, first_ref.range) =~ "  «first»"
    end

    test "in the match arms of a with" do
      {:ok, [var_def, var_2_def, var_ref], doc} =
        ~q[
          with {:ok, var} <- something(),
               {:ok, var_2} <- something_else(var) do
            :bad
          end
        ]
        |> index()

      assert_definition(var_def, :var)
      assert decorate(doc, var_def.range) =~ "{:ok, «var»} <- something(),"

      assert_definition(var_2_def, :var_2)
      assert decorate(doc, var_2_def.range) =~ "     {:ok, «var_2»} <- something_else(var) do"

      assert_reference(var_ref, :var)
      assert decorate(doc, var_ref.range) =~ "     {:ok, var_2} <- something_else(«var») do"
    end

    test "in the body of a with" do
      {:ok, [_var_def, var_ref], doc} =
        ~q[
          with {:ok, var} <- something() do
            var + 1
          end
        ]
        |> index()

      assert_reference(var_ref, :var)
      assert decorate(doc, var_ref.range) =~ "  «var» + 1"
    end

    test "in a comprehension" do
      {:ok, extracted, doc} =
        ~q[
          for {:ok, var} <- list,
              {:record, elem_1, elem_2} <- var do
            {:ok, elem_1 + elem_2}
          end
        ]
        |> index()

      assert [var_def, list_ref, elem_1_def, elem_2_def, var_ref, elem_1_ref, elem_2_ref] =
               extracted

      assert_definition(var_def, :var)
      assert decorate(doc, var_def.range) =~ "for {:ok, «var»} <- list,"

      assert_reference(list_ref, :list)
      assert decorate(doc, list_ref.range) =~ "for {:ok, var} <- «list»,"

      assert_definition(elem_1_def, :elem_1)
      assert decorate(doc, elem_1_def.range) =~ "{:record, «elem_1», elem_2} <- var do"

      assert_definition(elem_2_def, :elem_2)
      assert decorate(doc, elem_2_def.range) =~ "{:record, elem_1, «elem_2»} <- var do"

      assert_reference(var_ref, :var)
      assert decorate(doc, var_ref.range) =~ "{:record, elem_1, elem_2} <- «var» do"

      assert_reference(elem_1_ref, :elem_1)
      assert decorate(doc, elem_1_ref.range) =~ "  {:ok, «elem_1» + elem_2}"

      assert_reference(elem_2_ref, :elem_2)
      assert decorate(doc, elem_2_ref.range) =~ "  {:ok, elem_1 + «elem_2»}"
    end

    test "in guards in def functions" do
      {:ok, [param_def, param_2_def, param_ref], doc} =
        ~q[
          def something(param, param_2) when param > 1 do
          end
        ]
        |> index()

      assert_definition(param_def, :param)
      assert decorate(doc, param_def.range) =~ "def something(«param», param_2) when param > 1 do"

      assert_definition(param_2_def, :param_2)

      assert decorate(doc, param_2_def.range) =~
               "def something(param, «param_2») when param > 1 do"

      assert_reference(param_ref, :param)
      assert decorate(doc, param_ref.range) =~ "def something(param, param_2) when «param» > 1 do"
    end

    test "in guards in anonymous functions" do
      {:ok, [param_def, param_2_def, param_ref], doc} =
        ~q[
         fn param, param_2 when param > 1 -> :ok end
        ]
        |> index()

      assert_definition(param_def, :param)
      assert decorate(doc, param_def.range) =~ "fn «param», param_2 when param > 1 -> :ok end"

      assert_definition(param_2_def, :param_2)
      assert decorate(doc, param_2_def.range) =~ "fn param, «param_2» when param > 1 -> :ok end"

      assert_reference(param_ref, :param)
      assert decorate(doc, param_ref.range) =~ "fn param, param_2 when «param» > 1 -> :ok end"
    end
  end
end
