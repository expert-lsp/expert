defmodule Engine.Compilation.TracerTest do
  use ExUnit.Case, async: false
  use Patch

  import Forge.EngineApi.Messages

  alias Engine.Compilation.Tracer

  defmodule Fixture do
    defstruct [:field]

    def visible(argument), do: argument
    defmacro generated, do: :ok
  end

  test "broadcasts metadata for a compiled module" do
    test_pid = self()

    patch(Engine, :broadcast, fn message ->
      send(test_pid, message)
      :ok
    end)

    env = %{__ENV__ | file: "fixture.ex", module: Fixture}
    assert :ok = Tracer.trace({:on_module, <<>>, "fixture.ex"}, env)

    assert_receive module_updated(
                     file: "fixture.ex",
                     functions: functions,
                     macros: macros,
                     name: Fixture,
                     struct: struct
                   )

    assert {:visible, 1} in functions
    assert {:generated, 0} in macros
    assert %{field: :field, required?: false} in struct
  end
end
