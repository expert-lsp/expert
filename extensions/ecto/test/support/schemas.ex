defmodule ExpertEcto.Test.Post do
  @moduledoc false

  def __schema__(:fields), do: [:id, :name, :nickname]
  def __schema__(:associations), do: [:comments, :author]
  def __schema__(:association, :comments), do: %{related: ExpertEcto.Test.Comment}
  def __schema__(:association, _name), do: nil
end

defmodule ExpertEcto.Test.Comment do
  @moduledoc false

  def __schema__(:fields), do: [:id, :name, :body]
  def __schema__(:associations), do: []
  def __schema__(:association, _name), do: nil
end

defmodule ExpertEcto.Test.Money do
  @moduledoc false

  def type, do: :integer
  def cast(value), do: {:ok, value}
  def dump(value), do: {:ok, value}
  def load(value), do: {:ok, value}
end

defmodule ExpertEcto.Test.Event.Metadata do
  @moduledoc false

  def __schema__(:fields), do: [:id]
end

defmodule ExpertEcto.Test.Event.Metadata.Sink do
  @moduledoc false

  def __schema__(:fields), do: [:id]
end
