defmodule EftBuddy.EnvExampleTest do
  @moduledoc """
  `.env.example` documents every variable the deployment reads (audit L12).

  It had fallen behind: compose required `TUNNEL_TOKEN` and `runtime.exs` read
  eight variables it never mentioned, so a contributor following setup hit a
  compose error and could not discover the rest. This keeps it in step with
  both readers.
  """
  use ExUnit.Case, async: true

  # Not for `.env`: the Dockerfile sets PHX_SERVER, and GIT_SHA is a build
  # argument (see docker-compose.yml).
  @not_env ~w(PHX_SERVER GIT_SHA)

  defp code_lines(path) do
    path
    |> File.read!()
    |> String.split("\n")
    |> Enum.reject(&(String.trim_leading(&1) |> String.starts_with?("#")))
    |> Enum.join("\n")
  end

  defp documented do
    ~r/^#?\s*([A-Z][A-Z0-9_]*)=/m
    |> Regex.scan(File.read!(".env.example"), capture: :all_but_first)
    |> List.flatten()
    |> MapSet.new()
  end

  test "every variable runtime.exs reads is in .env.example" do
    read =
      ~r/(?:get_env|require_env\.|optional_int\.)\("([A-Z][A-Z0-9_]*)"/
      |> Regex.scan(code_lines("config/runtime.exs"), capture: :all_but_first)
      |> List.flatten()
      |> Enum.uniq()

    assert read != []
    assert (read -- @not_env) -- MapSet.to_list(documented()) == []
  end

  test "every variable docker-compose.yml interpolates is in .env.example" do
    read =
      ~r/\$\{([A-Z][A-Z0-9_]*)/
      |> Regex.scan(code_lines("docker-compose.yml"), capture: :all_but_first)
      |> List.flatten()
      |> Enum.uniq()

    assert "TUNNEL_TOKEN" in read
    assert (read -- @not_env) -- MapSet.to_list(documented()) == []
  end
end
