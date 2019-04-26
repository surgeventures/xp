defmodule Xp.Gen do
  @moduledoc false

  use Xp.Task

  # deps

  def gen_latest_dep(name, opts \\ []) do
    log_step(:green, "adding dep", name)

    name
    |> get_package_version()
    |> case do
      {:ok, version} ->
        semver = Version.parse!(version)
        req = "~> #{semver.major}.#{semver.minor}.#{semver.patch}"
        key = String.to_atom(name)

        dep =
          case opts do
            [] -> {key, req}
            opts_list -> {key, req, opts_list}
          end

        case gen_dep_quiet(dep) do
          :error -> {:error, :gen_dep, req}
          misc -> misc
        end

      :error ->
        {:error, :get_package_version}
    end
    |> log_gen_latest_dep_result(name)
  end

  defp log_gen_latest_dep_result(result, name) do
    case result do
      {:error, :get_package_version} ->
        log_info("Unable to find latest version of package :#{name} - please add it manually")

      {:error, :gen_dep, req} ->
        dep_string = "{:#{name}, #{inspect(req)}}"
        log_info("Unable to modify project config - please add `#{dep_string}` to deps manually")

      {:ok, _} ->
        nil
    end

    result
  end

  def gen_dep(dep) do
    name = elem(dep, 0)

    log_step(:green, "adding dep", name)

    dep
    |> gen_dep_quiet()
    |> log_gen_latest_dep_result(name)
  end

  def gen_dep_quiet(dep) do
    mix_path = "mix.exs"
    content = File.read!(mix_path)
    lines = String.split(content, "\n")
    dep_name = elem(dep, 0)
    dep_req = elem(dep, 1)
    dep_string = dep |> Macro.escape() |> Macro.to_string()

    with {_, {:ok, deps, last_dep_at, insert_dep_at}} <- {:parse_deps, parse_deps(lines)},
         {_, false} <- {:already_added, Enum.member?(deps, dep_name)} do
      lines =
        if last_dep_at do
          List.update_at(lines, last_dep_at, &String.replace(&1, ~r/(\s{4}{:.*})$/, "\\1,"))
        else
          lines
        end

      new_content =
        lines
        |> List.insert_at(insert_dep_at, dep_string)
        |> Enum.join("\n")
        |> Code.format_string!()

      File.write!(mix_path, new_content)

      {:ok, :added, dep_req}
    else
      {:already_added, _} -> {:ok, :already_added}
      {:parse_deps, _} -> {:error, :parse_deps}
    end
  end

  defp parse_deps(lines) do
    lines
    |> Enum.with_index()
    |> Enum.reduce(:no_func, fn
      {"  defp deps do", _}, :no_func ->
        :in_func

      {"    [" <> _, _}, :in_func ->
        {:in_list, [], nil}

      {"      {:" <> rest, at}, {:in_list, packages, _} ->
        [[package]] = Regex.scan(~r/^\w+/, rest)
        {:in_list, [String.to_atom(package) | packages], at}

      {"", _}, {:in_list, _, _} = acc ->
        acc

      {"      #" <> _, _}, {:in_list, _, _} = acc ->
        acc

      {"    ]" <> _, ends_at}, {:in_list, packages, last_at} ->
        {:after_list, packages, last_at, ends_at}

      _, {:in_list, _, _} ->
        :error

      {"  end", _}, {:after_list, packages, last_at, ends_at} ->
        {:ok, Enum.reverse(packages), last_at, ends_at}

      _, acc ->
        acc
    end)
    |> case do
      {:ok, _, _, _} = acc -> acc
      _ -> :error
    end
  end

  ## hex

  defp get_package_version(name) do
    with auth <- Mix.Tasks.Hex.auth_info(:read, auth_inline: false),
         {:ok, {200, packages, _}} <- Hex.API.Package.search(nil, name, auth),
         %{"releases" => releases} <- Enum.find(packages, &(&1["name"] == name)),
         %{"version" => version} = Enum.find(releases, &Hex.Version.stable?(&1["version"])) do
      {:ok, version}
    else
      _ -> :error
    end
  end

  ## ci

  @ci_config_path ".circleci/config.yml"

  @ci_config_default """
  version: 2
  jobs:
    build:
      docker:
        - image: circleci/elixir:1.5
      environment:
        - MIX_ENV: test
      working_directory: ~/repo
      steps:
        - checkout
        - run: mix local.hex --force
        - run: mix local.rebar --force
        - run: mix deps.get
  """

  def gen_ci_config do
    if match?(:ok, create_file(@ci_config_path, @ci_config_default)) do
      log_info([
        :yellow,
        "CircleCI config generated  - please add your project on https://circleci.com"
      ])
    end
  end

  def gen_ci_task(task) do
    log_step(:green, "adding task", task)

    task_step = "run: #{task}"

    with {_, {:ok, content}} <- {:read_config, File.read(@ci_config_path)},
         lines = String.split(content, "\n"),
         {_, {:ok, steps, insert_at}} <- {:parse_build_steps, parse_ci_config_build_steps(lines)},
         {_, false} <- {:already_added, Enum.any?(steps, &(&1 == task_step))} do
      new_content =
        lines
        |> List.insert_at(insert_at, "      - " <> task_step)
        |> Enum.join("\n")

      File.write!(@ci_config_path, new_content)

      {:ok, :added}
    else
      {:read_config, _} -> {:error, :read_config}
      {:parse_build_steps, _} -> {:error, :parse_build_steps}
      {:already_added, _} -> {:ok, :already_added}
    end
    |> log_gen_ci_task_result(task)
  end

  def log_gen_ci_task_result(result, task) do
    case result do
      {:error, :read_config} ->
        log_error("No CI config - please generate it via `mix xp.gen.ci`")

      {:error, :parse_build_steps} ->
        log_error("Unable to modify CI config - please add task `#{task}` manually")

      {:ok, _} ->
        nil
    end

    result
  end

  defp parse_ci_config_build_steps(lines) do
    lines
    |> Enum.with_index()
    |> Enum.reduce(:top, fn
      {"jobs:", _}, :top ->
        :jobs

      {"  build:", _}, :jobs ->
        :build_job

      {"    steps:", _}, :build_job ->
        {:build_job_steps, []}

      {"      - " <> step, _}, {:build_job_steps, steps} ->
        {:build_job_steps, [step | steps]}

      {_, ends_at}, {:build_job_steps, steps} ->
        {:ok, Enum.reverse(steps), ends_at}

      _, acc ->
        acc
    end)
    |> case do
      {:ok, _, _} = acc -> acc
      _ -> :error
    end
  end

  ## credo

  @credo_config_path ".credo.exs"

  @credo_config_default """
  %{
    configs: [
      %{
        name: "default",
        files: %{
          included: ["lib/", "test/"]
        },
        strict: true,
        color: true,
        checks: [
          {Credo.Check.Readability.MaxLineLength, [max_length: 100]}
        ]
      }
    ]
  }
  """

  def gen_credo_config do
    create_file(@credo_config_path, @credo_config_default)
  end

  ## formatter

  @formatter_config_path ".formatter.exs"

  @formatter_config_default """
  [
    inputs: ["*.{ex,exs}", "{config,lib,test}/**/*.{ex,exs}"],
    line_length: 100
  ]
  """

  def gen_formatter_config do
    create_file(@formatter_config_path, @formatter_config_default)
  end

  @license_path "LICENSE.md"

  @license_default """
  Permission is hereby granted, free of charge, to any person obtaining a copy
  of this software and associated documentation files (the "Software"), to deal
  in the Software without restriction, including without limitation the rights
  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
  copies of the Software, and to permit persons to whom the Software is
  furnished to do so, subject to the following conditions:

  The above copyright notice and this permission notice shall be included in all
  copies or substantial portions of the Software.

  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
  SOFTWARE.
  """

  def gen_license do
    create_file(@license_path, @license_default)
  end
end
