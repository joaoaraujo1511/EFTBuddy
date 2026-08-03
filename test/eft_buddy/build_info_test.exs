defmodule EftBuddy.BuildInfoTest do
  @moduledoc """
  The value reported here is what a deployer trusts when asking "did my deploy
  land?", so the failure that matters is not an exception — it is reporting a
  plausible-looking wrong answer, or refusing to boot over build metadata.
  """
  # `async: false`: these mutate the OS process environment, which every other
  # test shares.
  use ExUnit.Case, async: false

  alias EftBuddy.BuildInfo

  setup do
    original = System.get_env("GIT_SHA")

    on_exit(fn ->
      if original, do: System.put_env("GIT_SHA", original), else: System.delete_env("GIT_SHA")
    end)

    :ok
  end

  test "reports the revision the build argument supplied" do
    System.put_env("GIT_SHA", "abc1234")

    assert BuildInfo.sha() == "abc1234"
  end

  test "trims the newline a `git rev-parse` pipeline leaves behind" do
    # `GIT_SHA=$(git rev-parse --short HEAD)` strips it, but a Dockerfile ARG fed
    # from a file or a CI variable frequently does not, and a trailing newline in
    # a JSON field is invisible until someone diffs two values that look equal.
    System.put_env("GIT_SHA", "abc1234\n")

    assert BuildInfo.sha() == "abc1234"
  end

  test "falls back instead of raising when the build argument was omitted" do
    # A release that cannot name its revision is still a working release. Failing
    # a boot here would trade a minor annoyance for an outage.
    System.delete_env("GIT_SHA")

    assert BuildInfo.sha() == "dev"
  end

  test "treats an empty build argument as absent" do
    # `GIT_SHA: "${GIT_SHA:-}"` in docker-compose.yml passes an empty STRING, not
    # nothing, when the operator forgets the prefix on the build command — so the
    # nil clause alone would let `""` through as if it were a revision.
    System.put_env("GIT_SHA", "")

    assert BuildInfo.sha() == "dev"
  end
end
