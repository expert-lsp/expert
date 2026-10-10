defmodule Forge.Completion.Candidate do
  alias Forge.Completion.Candidate.ArgumentNames

  require Logger

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

    def new(%{} = elixir_sense_map) do
      arg_names =
        case ArgumentNames.from_elixir_sense_map(elixir_sense_map) do
          :error -> []
          names -> names
        end

      __MODULE__
      |> struct(elixir_sense_map)
      |> Map.put(:argument_names, arg_names)
    end
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

    def new(%{} = elixir_sense_map) do
      arg_names =
        case ArgumentNames.from_elixir_sense_map(elixir_sense_map) do
          :error -> []
          names -> names
        end

      __MODULE__
      |> struct(elixir_sense_map)
      |> Map.put(:argument_names, arg_names)
    end
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
      :summary,
      :metadata,
      parens?: true
    ]

    def new(%{} = elixir_sense_map) do
      arg_names =
        case ArgumentNames.from_elixir_sense_map(elixir_sense_map) do
          :error -> []
          names -> names
        end

      __MODULE__
      |> struct(elixir_sense_map)
      |> Map.put(:argument_names, arg_names)
    end
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

    def new(%{} = elixir_sense_map) do
      arg_names =
        case ArgumentNames.from_elixir_sense_map(elixir_sense_map) do
          :error -> []
          names -> names
        end

      __MODULE__
      |> struct(elixir_sense_map)
      |> Map.put(:argument_names, arg_names)
    end
  end

  defmodule Module do
    @moduledoc false
    defstruct [:full_name, :metadata, :name, :summary]

    def new(%{} = elixir_sense_map) do
      struct(__MODULE__, elixir_sense_map)
    end
  end

  defmodule Exception do
    @moduledoc false
    defstruct [:full_name, :metadata, :name, :summary]

    def new(%{} = elixir_sense_map) do
      struct(__MODULE__, elixir_sense_map)
    end
  end

  defmodule Behaviour do
    @moduledoc false
    defstruct [:full_name, :metadata, :name, :summary]

    def new(%{} = elixir_sense_map) do
      struct(__MODULE__, elixir_sense_map)
    end
  end

  defmodule Protocol do
    @moduledoc false
    defstruct [:full_name, :metadata, :name, :summary]

    def new(%{} = elixir_sense_map) do
      struct(__MODULE__, elixir_sense_map)
    end
  end

  defmodule Struct do
    @moduledoc false
    defstruct [:full_name, :metadata, :name, :summary]

    def new(%{} = elixir_sense_map) do
      struct(__MODULE__, elixir_sense_map)
    end
  end

  defmodule StructField do
    @moduledoc false
    defstruct [:call?, :name, :origin, :type_spec]

    def new(%{} = elixir_sense_map) do
      struct(__MODULE__, elixir_sense_map)
    end

    def new(name, origin) do
      %__MODULE__{name: name, origin: origin, call?: false}
    end
  end

  defmodule MapField do
    @moduledoc false
    defstruct [:call?, :name]

    def new(%{} = elixir_sense_map) do
      struct(__MODULE__, elixir_sense_map)
    end
  end

  defmodule ModuleAttribute do
    @moduledoc false
    defstruct [:name]

    def new(%{} = elixir_sense_map) do
      struct(__MODULE__, elixir_sense_map)
    end
  end

  defmodule Variable do
    @moduledoc false
    defstruct [:name]

    def new(%{} = elixir_sense_map) do
      struct(__MODULE__, elixir_sense_map)
    end
  end

  defmodule Snippet do
    @moduledoc false
    defstruct [:detail, :documentation, :filter_text, :kind, :label, :priority, :snippet]

    def new(%{} = elixir_sense_map) do
      struct(__MODULE__, elixir_sense_map)
    end
  end

  defmodule Generic do
    @moduledoc false
    defstruct [
      :detail,
      :documentation,
      :filter_text,
      :insert_text,
      :kind,
      :label,
      :priority,
      :snippet
    ]

    def new(%{} = elixir_sense_map) do
      struct(__MODULE__, elixir_sense_map)
    end
  end

  defmodule MixTask do
    defstruct [:full_name, :metadata, :name, :subtype, :summary, :type]

    def new(%{} = elixir_sense_map) do
      struct(__MODULE__, elixir_sense_map)
    end
  end

  defmodule BitstringOption do
    defstruct [:name, :type]

    def new(%{} = elixir_sense_map) do
      struct(__MODULE__, elixir_sense_map)
    end
  end

  def from_elixir_sense(%{type: :module, subtype: nil} = elixir_sense_map) do
    Module.new(elixir_sense_map)
  end

  def from_elixir_sense(%{type: :module, subtype: :alias} = elixir_sense_map) do
    Module.new(elixir_sense_map)
  end

  def from_elixir_sense(%{type: :module, subtype: :behaviour} = elixir_sense_map) do
    Behaviour.new(elixir_sense_map)
  end

  def from_elixir_sense(%{type: :module, subtype: :exception} = elixir_sense_map) do
    Exception.new(elixir_sense_map)
  end

  def from_elixir_sense(%{type: :module, subtype: :struct} = elixir_sense_map) do
    Struct.new(elixir_sense_map)
  end

  def from_elixir_sense(%{type: :module, subtype: :protocol} = elixir_sense_map) do
    Protocol.new(elixir_sense_map)
  end

  def from_elixir_sense(%{type: :module, subtype: :task} = elixir_sense_map) do
    MixTask.new(elixir_sense_map)
  end

  # elixir_sense suggests test cases as functions, which need to be filtered.
  def from_elixir_sense(%{type: :function, name: "test " <> _} = _elixir_sense_map) do
    nil
  end

  def from_elixir_sense(%{type: :function} = elixir_sense_map) do
    Function.new(elixir_sense_map)
  end

  def from_elixir_sense(%{type: :macro} = elixir_sense_map) do
    Macro.new(elixir_sense_map)
  end

  def from_elixir_sense(%{type: :type_spec} = elixir_sense_map) do
    Typespec.new(elixir_sense_map)
  end

  def from_elixir_sense(%{type: :bitstring_option} = elixir_sense_map) do
    BitstringOption.new(elixir_sense_map)
  end

  def from_elixir_sense(%{type: :attribute} = elixir_sense_map) do
    ModuleAttribute.new(elixir_sense_map)
  end

  def from_elixir_sense(%{type: :generic, kind: :snippet} = elixir_sense_map) do
    Snippet.new(elixir_sense_map)
  end

  def from_elixir_sense(%{type: :generic} = elixir_sense_map) do
    Generic.new(elixir_sense_map)
  end

  def from_elixir_sense(%{type: :variable} = elixir_sense_map) do
    Variable.new(elixir_sense_map)
  end

  def from_elixir_sense(%{type: :field, subtype: :struct_field} = elixir_sense_map) do
    StructField.new(elixir_sense_map)
  end

  def from_elixir_sense(%{type: :field, subtype: :map_key} = elixir_sense_map) do
    MapField.new(elixir_sense_map)
  end

  def from_elixir_sense(%{type: :callback} = elixir_sense_map) do
    Callback.new(elixir_sense_map)
  end

  def from_elixir_sense(elixir_sense_map) do
    Logger.warning("Unhandled completion suggestion: #{inspect(elixir_sense_map)}")
    nil
  end
end
