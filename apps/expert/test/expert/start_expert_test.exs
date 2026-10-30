defmodule Expert.StartExpertTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  @vm_flag_vars ["ELIXIR_ERL_OPTIONS", "ERL_AFLAGS", "ERL_FLAGS", "ERL_ZFLAGS"]

  if match?({:unix, _}, :os.type()) do
    test "starts the release without the editor's VM flags", %{tmp_dir: tmp_dir} do
      start_expert = Path.join(tmp_dir, "start_expert")
      File.cp!(Path.expand("../../rel/unix/bin/start_expert", __DIR__), start_expert)

      plain = Path.join(tmp_dir, "plain")
      File.write!(plain, "#!/bin/sh\nenv\n")
      File.chmod!(plain, 0o755)

      env = Enum.map(@vm_flag_vars, &{&1, "-epmd_module Elixir.Livebook.EPMD"})
      {output, 0} = System.cmd("/bin/sh", [start_expert, "--stdio"], env: env)

      for var <- @vm_flag_vars do
        refute output =~ "#{var}="
      end
    end
  end
end
