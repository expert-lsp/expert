defmodule Expert.CodeIntelligence.Completion.Candidate do
  @moduledoc """
  Defines completion candidates before their conversion to LSP items.
  """

  defmodule Function do
    @moduledoc false
    defstruct [
      :argument_names,
      :arity,
      :name,
      :origin,
      :type,
      :visibility,
      :spec,
      :summary,
      :metadata,
      parens?: true
    ]
  end

  defmodule Callback do
    @moduledoc false
    defstruct [
      :argument_names,
      :arity,
      :metadata,
      :name,
      :origin,
      :spec,
      :summary,
      :type,
      parens?: true
    ]
  end

  defmodule Macro do
    @moduledoc false
    defstruct [
      :argument_names,
      :arity,
      :name,
      :origin,
      :type,
      :visibility,
      :spec,
      :metadata,
      parens?: true
    ]
  end

  defmodule Typespec do
    @moduledoc false
    defstruct [
      :argument_names,
      :arity,
      :doc,
      :metadata,
      :type,
      :name,
      :origin,
      :signature,
      :spec,
      parens?: true
    ]
  end

  defmodule Module do
    @moduledoc false
    defstruct [:full_name, :metadata, :name, :summary]
  end

  defmodule Exception do
    @moduledoc false
    defstruct [:full_name, :metadata, :name, :summary]
  end

  defmodule Behaviour do
    @moduledoc false
    defstruct [:full_name, :metadata, :name, :summary]
  end

  defmodule Protocol do
    @moduledoc false
    defstruct [:full_name, :metadata, :name, :summary]
  end

  defmodule Struct do
    @moduledoc false
    defstruct [:full_name, :metadata, :name, :summary]
  end

  defmodule StructField do
    @moduledoc false
    defstruct [:call?, :name, :origin, :type_spec]

    def new(name, origin) do
      %__MODULE__{name: name, origin: origin, call?: false}
    end
  end

  defmodule MapField do
    @moduledoc false
    defstruct [:call?, :name]
  end

  defmodule ModuleAttribute do
    @moduledoc false
    defstruct [:name]
  end

  defmodule Variable do
    @moduledoc false
    defstruct [:name]
  end

  defmodule Snippet do
    @moduledoc false
    defstruct [:detail, :documentation, :filter_text, :kind, :label, :priority, :snippet]
  end

  defmodule MixTask do
    defstruct [:full_name, :metadata, :name, :subtype, :summary, :type]
  end

  defmodule BitstringOption do
    defstruct [:name, :type]
  end
end
