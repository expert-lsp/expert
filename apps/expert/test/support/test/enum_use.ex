defmodule Expert.Test.EnumUse do
  @moduledoc false

  defmacro __using__(_opts) do
    quote do
      import Enum, only: [map: 2]
    end
  end
end
