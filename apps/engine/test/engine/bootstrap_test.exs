defmodule Engine.BootstrapTest do
  use ExUnit.Case, async: true

  alias Engine.Bootstrap

  @moduletag :tmp_dir

  test "appends the user's archives except Hex to the code path", %{tmp_dir: tmp_dir} do
    nerves_ebin = archive_ebin(tmp_dir, "nerves_bootstrap-1.13.0")
    hex_ebin = archive_ebin(tmp_dir, "hex-2.5.3")
    on_exit(fn -> Code.delete_path(nerves_ebin) end)

    assert :ok = Bootstrap.append_user_archives(tmp_dir)

    code_path = :code.get_path()
    assert String.to_charlist(nerves_ebin) in code_path
    refute String.to_charlist(hex_ebin) in code_path
  end

  defp archive_ebin(archives_path, name) do
    ebin = archives_path |> Path.join(name) |> Mix.Local.archive_ebin()
    File.mkdir_p!(ebin)
    ebin
  end
end
