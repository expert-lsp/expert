Forge.Identifier.start()
Application.ensure_all_started(:forge)

random_number = :rand.uniform(500)

with :nonode@nohost <- Node.self() do
  {:ok, _pid} =
    Node.start(:"expert-manager-testing-#{random_number}@127.0.0.1", :longnames)
end

Engine.Module.Loader.start_link(nil)
ExUnit.configure(assert_receive_timeout: 1000)

ExUnit.start(exclude: [:skip])

if Version.match?(System.version(), ">= 1.15.0") do
  Logger.configure(level: :none)
else
  LoggerBackends.remove(:console)
end
