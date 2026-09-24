defmodule Expert.Configuration do
  @moduledoc """
  Encapsulates expert configuration options and client capability support.
  """

  alias Expert.Configuration.Support
  alias Expert.Configuration.WorkspaceSymbols
  alias Expert.Protocol.Id
  alias GenLSP.Notifications.WorkspaceDidChangeConfiguration
  alias GenLSP.Requests
  alias GenLSP.Structures

  @default_lsp_log_level :info
  @default_file_log_level :debug

  @lsp_log_levels %{
    "error" => :error,
    "warning" => :warning,
    "info" => :info,
    "log" => :log
  }

  @file_log_levels %{
    "debug" => :debug,
    "info" => :info,
    "warning" => :warning,
    "error" => :error
  }

  @settings %{
    log_level: %{
      key: "logLevel",
      parser: {:enum, @lsp_log_levels, @default_lsp_log_level},
      missing: :default
    },
    file_log_level: %{
      key: "fileLogLevel",
      parser: {:enum, @file_log_levels, @default_file_log_level},
      missing: :preserve
    },
    elixir_source_path: %{
      key: "elixirSourcePath",
      parser: {:string, nil},
      missing: :preserve
    },
    elixir_executable_path: %{
      key: "elixirExecutablePath",
      parser: {:string, nil},
      missing: :preserve
    },
    erlang_executable_path: %{
      key: "erlangExecutablePath",
      parser: {:string, nil},
      missing: :preserve
    },
    auto_fetch_dependencies: %{
      key: "autoFetchDependencies",
      parser: {:boolean, true},
      missing: :preserve
    },
    compile_on_type: %{
      key: "compileOnType",
      parser: {:boolean, true},
      missing: :preserve
    },
    workspace_symbols: %{
      key: "workspaceSymbols",
      parser: :workspace_symbols,
      missing: :preserve
    }
  }

  @type lsp_level :: :error | :warning | :info | :log
  @type file_level :: :debug | :info | :warning | :error

  defstruct support: nil,
            client_name: nil,
            additional_watched_extensions: nil,
            workspace_symbols: %WorkspaceSymbols{},
            log_level: @default_lsp_log_level,
            file_log_level: @default_file_log_level,
            elixir_source_path: nil,
            elixir_executable_path: nil,
            erlang_executable_path: nil,
            auto_fetch_dependencies: true,
            compile_on_type: true

  @type t :: %__MODULE__{
          support: support | nil,
          client_name: String.t() | nil,
          additional_watched_extensions: [String.t()] | nil,
          workspace_symbols: WorkspaceSymbols.t(),
          log_level: lsp_level(),
          file_log_level: file_level(),
          elixir_source_path: String.t() | nil,
          elixir_executable_path: String.t() | nil,
          erlang_executable_path: String.t() | nil,
          auto_fetch_dependencies: boolean(),
          compile_on_type: boolean()
        }

  @opaque support :: Support.t()

  @spec new(Structures.ClientCapabilities.t(), String.t() | nil) :: t
  def new(%Structures.ClientCapabilities{} = client_capabilities, client_name) do
    support = Support.new(client_capabilities)

    %__MODULE__{support: support, client_name: client_name}
  end

  @spec new(keyword()) :: t
  def new(attrs \\ []) do
    struct!(__MODULE__, [support: Support.new()] ++ attrs)
  end

  @spec set(t) :: t
  def set(%__MODULE__{} = config) do
    :persistent_term.put(__MODULE__, config)
    config
  end

  @spec get() :: t
  def get do
    :persistent_term.get(__MODULE__, nil) || struct!(__MODULE__, support: Support.new())
  end

  @spec client_support(atom()) :: term()
  def client_support(key) when is_atom(key) do
    client_support(get().support, key)
  end

  @doc """
  Whether the client can lazily resolve a code action's `edit` property via `codeAction/resolve`.
  When true, the server defers computing refactor edits until an action is actually invoked.

  https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#clientCodeActionResolveOptions
  """
  @spec client_resolves_code_action_edits?() :: boolean()
  def client_resolves_code_action_edits? do
    case client_support(:code_action_resolve) do
      %{properties: properties} when is_list(properties) -> "edit" in properties
      _ -> false
    end
  end

  @spec log_level() :: lsp_level()
  def log_level do
    get().log_level
  end

  @spec file_log_level() :: file_level()
  def file_log_level do
    get().file_log_level
  end

  @spec auto_fetch_dependencies?() :: boolean()
  def auto_fetch_dependencies? do
    get().auto_fetch_dependencies
  end

  @spec compile_on_type?() :: boolean()
  def compile_on_type? do
    get().compile_on_type
  end

  @vscode_family_patterns [
    "visual studio code",
    "cursor",
    "windsurf",
    "vscodium",
    "positron",
    "code-server"
  ]

  @spec vscode_family?() :: boolean()
  def vscode_family? do
    case get().client_name do
      nil ->
        false

      client_name ->
        downcased = client_name |> String.trim() |> String.downcase()
        Enum.any?(@vscode_family_patterns, &String.contains?(downcased, &1))
    end
  end

  @spec window_log_message_enabled?() :: boolean()
  def window_log_message_enabled? do
    case get().client_name do
      nil ->
        true

      client_name ->
        # Workaround for Eglot/Emacs behavior discussed in:
        # https://github.com/expert-lsp/expert/issues/382
        client_name
        |> String.trim()
        |> String.downcase()
        |> then(&(&1 not in ["emacs", "eglot"]))
    end
  end

  defp client_support(%Support{} = client_support, key) do
    case Map.fetch(client_support, key) do
      {:ok, value} -> value
      :error -> raise ArgumentError, "unknown key: #{inspect(key)}"
    end
  end

  @spec default() :: {:ok, t} | {:ok, t, Requests.ClientRegisterCapability.t()}
  def default do
    apply_config_change(get(), %{})
  end

  @spec on_change(WorkspaceDidChangeConfiguration.t() | :defaults) ::
          {:ok, t}
          | {:ok, t, Requests.ClientRegisterCapability.t()}
  def on_change(:defaults) do
    apply_config_change(get(), %{})
  end

  def on_change(%WorkspaceDidChangeConfiguration{} = change) do
    apply_config_change(get(), change.params.settings)
  end

  defp apply_config_change(%__MODULE__{} = old_config, %{} = settings) do
    new_config =
      old_config
      |> apply_settings(settings)
      |> set()

    apply_file_log_level(new_config)
    maybe_watched_extensions_request(new_config, settings)
  end

  defp apply_config_change(%__MODULE__{} = old_config, _settings) do
    {:ok, old_config}
  end

  defp apply_file_log_level(%__MODULE__{file_log_level: level}) do
    handler_name = Expert.Logging.ProjectLogFile.handler_name()

    case :logger.set_handler_config(handler_name, :level, level) do
      :ok -> :ok
      {:error, _} -> :ok
    end
  end

  defp apply_settings(%__MODULE__{} = config, settings) do
    Enum.reduce(@settings, config, fn {field, setting}, config ->
      apply_setting(config, settings, field, setting)
    end)
  end

  defp apply_setting(%__MODULE__{} = config, settings, field, %{
         key: key,
         parser: parser,
         missing: on_missing
       }) do
    case Map.fetch(settings, key) do
      {:ok, value} -> put_setting(config, field, parse_setting(value, parser))
      :error -> apply_missing_setting(config, field, parser, on_missing)
    end
  end

  defp apply_missing_setting(%__MODULE__{} = config, field, parser, :default) do
    put_setting(config, field, default_setting(parser))
  end

  defp apply_missing_setting(%__MODULE__{} = config, _field, _parser, :preserve) do
    config
  end

  defp parse_setting(value, {:enum, values, default}) do
    Map.get(values, value, default)
  end

  defp parse_setting(value, {:string, _default}) when is_binary(value) do
    value
  end

  defp parse_setting(_value, {:string, default}) do
    default
  end

  defp parse_setting(value, {:boolean, _default}) when is_boolean(value) do
    value
  end

  defp parse_setting(_value, {:boolean, default}) do
    default
  end

  defp parse_setting(settings, :workspace_symbols) do
    WorkspaceSymbols.new(%{"workspaceSymbols" => settings})
  end

  defp default_setting({:enum, _values, default}), do: default
  defp default_setting({:string, default}), do: default
  defp default_setting({:boolean, default}), do: default

  defp put_setting(%__MODULE__{} = config, field, value) do
    struct!(config, [{field, value}])
  end

  defp maybe_watched_extensions_request(
         %__MODULE__{support: %Support{watched_files_dynamic_registration: true}} = config,
         %{"additionalWatchedExtensions" => extensions}
       )
       when is_list(extensions) and extensions != [] do
    register_id = Id.next()
    request_id = Id.next()

    watchers = Enum.map(extensions, fn ext -> %{"globPattern" => "**/*#{ext}"} end)

    registration =
      %Structures.Registration{
        id: request_id,
        method: "workspace/didChangeWatchedFiles",
        register_options: %{"watchers" => watchers}
      }

    request = %Requests.ClientRegisterCapability{
      id: register_id,
      params: %Structures.RegistrationParams{registrations: [registration]}
    }

    {:ok, config, request}
  end

  defp maybe_watched_extensions_request(%__MODULE__{} = config, _settings) do
    {:ok, config}
  end
end
