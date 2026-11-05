const std = @import("std");
const builtin = @import("builtin");

// Expert's VM takes its flags from vm.args only. Flags from the editor's
// environment, like Livebook's -epmd_module, would override Expert's own.
// erl reads these variables itself. Burrito's wrapper copies the process
// environment for erl after this plugin has run, so deleting them from the
// process environment here keeps them from erl.
const vm_flag_vars = [_][:0]const u8{ "ELIXIR_ERL_OPTIONS", "ERL_AFLAGS", "ERL_FLAGS", "ERL_ZFLAGS" };

// Burrito calls this before it unpacks the release. Zig refuses to compile a
// function that leaves a parameter unused, and `_ = x` marks x as used.
pub fn burrito_plugin_entry(install_dir: []const u8, program_manifest_json: []const u8) void {
    _ = install_dir;
    _ = program_manifest_json;

    inline for (vm_flag_vars) |name| unsetEnvVar(name);
}

// Neither call can fail here. unsetenv rejects only an empty name or one
// containing `=`. SetEnvironmentVariableW with a null value deletes the
// variable and reports failure only when it was not set, which leaves the
// environment as wanted either way.
fn unsetEnvVar(comptime name: [:0]const u8) void {
    if (builtin.os.tag == .windows) {
        _ = std.os.windows.kernel32.SetEnvironmentVariableW(std.unicode.utf8ToUtf16LeStringLiteral(name), null);
    } else {
        _ = unsetenv(name);
    }
}

// The wrapper links libc. Zig's std.c has no binding for unsetenv.
extern "c" fn unsetenv(name: [*:0]const u8) c_int;
