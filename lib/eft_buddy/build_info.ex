defmodule EftBuddy.BuildInfo do
  @moduledoc """
  Names the exact source revision this release was built from.

  ## Why this exists

  Verifying a deploy means proving four separate states agree: `origin/main`,
  the checkout on the host, the image built from it, and the container running
  that image. Any adjacent pair can drift, and the drift is silent — a container
  that was never recreated keeps serving the previous image's code while a new
  commit sits in the checkout above it, and nothing about the running app
  contradicts you.

  The old procedure was four commands (`git log`, `docker image inspect`,
  `docker inspect`, plus an `rpc` probing whether some newly added function
  existed) with their timestamps compared by eye. That is a lot of ceremony to
  answer one question, and it is wrong precisely when it matters — during a
  hurried deploy.

  Baking the commit into the image collapses all of it into one request:

      curl -s https://…/health | jq -r .version

  ## Where the value comes from

  `GIT_SHA` is a **Docker build argument**, not a runtime variable. `.git` is
  excluded from the build context (see `.dockerignore`, which keeps the context
  small and credentials out of layers), so the builder cannot resolve the
  revision on its own — it has to be handed in by whoever runs the build.
  `docker-compose.yml` declares the argument and documents the invocation.

  Absent the argument this reports `"unknown"` rather than raising. A release
  that cannot name its own revision is still a perfectly working release, and
  failing a boot over build metadata would trade a minor annoyance for an
  outage. Under `mix phx.server` it reports `"dev"`, which is the honest answer
  for a working tree that may not correspond to any commit at all.
  """

  # Resolved at compile time so a release can distinguish "built without the
  # build arg" from "not built at all". Only :prod is ever packaged into an
  # image, so anything else is a working tree.
  @fallback if Mix.env() == :prod, do: "unknown", else: "dev"

  @doc """
  The short commit this build came from, or a fallback describing why it is
  unavailable (`"unknown"` in a release, `"dev"` in a working tree).

  Read at call time rather than compile time: the value is set by `ENV` in the
  runtime image, which does not exist yet while the builder is compiling.
  """
  @spec sha() :: String.t()
  def sha do
    case System.get_env("GIT_SHA") do
      nil -> @fallback
      "" -> @fallback
      sha -> String.trim(sha)
    end
  end
end
