defmodule Expert.Stdio.User.State do
  @moduledoc false

  defstruct [:stderr, :port, owner: nil, reader: nil, pending: <<>>, eof?: false]

  def new(stderr, port), do: %__MODULE__{stderr: stderr, port: port}
end
