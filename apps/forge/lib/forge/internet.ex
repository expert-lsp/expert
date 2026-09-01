defmodule Forge.Internet do
  def connected_to_internet? do
    # While there's no perfect way to check if a computer is connected to the internet,
    # it seems reasonable to gate pulling dependencies on a resolution check for hex.pm.
    # Yes, it's entirely possible that the DNS server is local, and that the entry is in cache,
    # but that's an edge case, and the build will just time out anyways.
    case :inet.gethostbyname(~c"hex.pm", :inet, 5_000) do
      {:ok, _} -> true
      _ -> false
    end
  end
end
