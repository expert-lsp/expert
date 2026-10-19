defmodule Expert.Namespace.Code do
  def compile(forms) do
    :compile.forms(forms, [:return_errors, :debug_info])
  end
end
