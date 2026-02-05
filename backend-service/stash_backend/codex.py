from __future__ import annotations

import json
import logging
import os
import re
import shlex
import subprocess
import sysconfig
from pathlib import Path

from .config import Settings
from .integrations import is_codex_model_config_error, resolve_binary
from .runtime_config import RuntimeConfig, RuntimeConfigStore
from .types import ExecutionResult, ProjectContext, TaggedCommand
from .utils import ensure_inside, stable_slug, utc_now_iso

TAG_RE = re.compile(r"<codex_cmd>(.*?)</codex_cmd>", flags=re.DOTALL | re.IGNORECASE)
logger = logging.getLogger(__name__)
CODEX_EXEC_REASONING_EFFORT = "low"

ALLOWED_PREFIXES = {
    "ls",
    "cat",
    "pwd",
    "echo",
    "mkdir",
    "touch",
    "cp",
    "mv",
    "find",
    "grep",
    "sed",
    "awk",
    "git",
    "python",
    "python3",
    "pytest",
    "uv",
    "npm",
    "node",
    "sh",
    "bash",
}


class CodexCommandError(Exception):
    pass


def parse_tagged_commands(text: str) -> list[TaggedCommand]:
    commands: list[TaggedCommand] = []
    for match in TAG_RE.finditer(text):
        raw_block = match.group(1).strip()
        fields: dict[str, str] = {}
        current_key: str | None = None

        for raw_line in raw_block.splitlines():
            line = raw_line.rstrip()
            if not line.strip():
                continue

            key = None
            value = None
            if ":" in line:
                candidate_key, candidate_value = line.split(":", 1)
                ck = candidate_key.strip().lower()
                if ck in {"worktree", "cwd", "cmd"}:
                    key = ck
                    value = candidate_value.lstrip()

            if key is not None:
                fields[key] = value or ""
                current_key = key
                continue

            if current_key == "cmd":
                fields["cmd"] = (fields.get("cmd", "") + "\n" + line).strip()

        cmd = fields.get("cmd", "").strip()
        if not cmd:
            continue

        commands.append(
            TaggedCommand(
                raw=raw_block,
                cmd=cmd,
                worktree=fields.get("worktree") or None,
                cwd=fields.get("cwd") or None,
            )
        )
    return commands


class CodexExecutor:
    def __init__(self, settings: Settings, runtime_config_store: RuntimeConfigStore | None = None):
        self.settings = settings
        self.runtime_config_store = runtime_config_store

    def _runtime_config(self) -> RuntimeConfig:
        if self.runtime_config_store is not None:
            return self.runtime_config_store.get()
        return RuntimeConfig.from_settings(self.settings)

    def _resolve_worktree(self, context: ProjectContext, worktree_label: str | None) -> Path:
        label = worktree_label or "default"
        worktree_name = stable_slug(label)
        target = context.stash_dir / "worktrees" / worktree_name
        target.mkdir(parents=True, exist_ok=True)
        return target

    def _resolve_cwd(self, context: ProjectContext, command: TaggedCommand, worktree_path: Path) -> Path:
        if command.cwd:
            raw = Path(command.cwd).expanduser()
            if raw.is_absolute():
                target = raw.resolve()
            else:
                # Relative cwd is project-root relative so planner output like "." maps to user files.
                target = (context.root_path / raw).resolve()
        else:
            target = context.root_path.resolve()

        if ensure_inside(context.root_path, target) or ensure_inside(worktree_path, target):
            return target

        raise CodexCommandError("Resolved cwd escapes project root/worktree boundary")

    def _validate_command(self, cmd: str) -> None:
        try:
            head = shlex.split(cmd)[0]
        except (ValueError, IndexError):
            raise CodexCommandError("Invalid command syntax")

        if head == "sudo":
            raise CodexCommandError("sudo is blocked. Adjust folder ownership/permissions first")

        if head not in ALLOWED_PREFIXES:
            raise CodexCommandError(f"Command prefix '{head}' is not in allowlist")

    def _build_codex_exec_prompt(self, command: str) -> str:
        return (
            "Execute exactly one shell command in the current working directory.\n"
            "Do not run additional commands.\n"
            "Do not reformat or modify the command.\n"
            "Command:\n"
            f"{command}\n"
        )

    def _run_command_via_shell(self, *, cwd: Path, command: str, env: dict[str, str]) -> tuple[int, str, str]:
        proc = subprocess.run(
            ["bash", "-lc", command],
            cwd=str(cwd),
            env=env,
            capture_output=True,
            text=True,
            timeout=600,
            check=False,
        )
        return int(proc.returncode), proc.stdout, proc.stderr

    def _parse_codex_json_events(self, output: str) -> tuple[int, str, str]:
        command_event: dict[str, object] | None = None
        last_agent_message = ""

        for raw_line in output.splitlines():
            line = raw_line.strip()
            if not line or not line.startswith("{"):
                continue
            try:
                event = json.loads(line)
            except json.JSONDecodeError:
                continue

            if event.get("type") != "item.completed":
                continue
            item = event.get("item") or {}
            if not isinstance(item, dict):
                continue
            item_type = item.get("type")
            if item_type == "command_execution":
                command_event = item
            elif item_type == "agent_message":
                text = item.get("text")
                if isinstance(text, str):
                    last_agent_message = text

        if command_event is None:
            # Codex returned no executable event; surface raw output for visibility.
            return 1, "", output.strip() or "Codex CLI did not emit command execution output."

        exit_code = int(command_event.get("exit_code") or 0)
        aggregated = str(command_event.get("aggregated_output") or "")
        status = str(command_event.get("status") or "")

        if exit_code == 0:
            return exit_code, aggregated, ""

        if aggregated:
            return exit_code, "", aggregated
        if last_agent_message:
            return exit_code, "", last_agent_message
        return exit_code, "", f"Command failed (status={status or 'failed'})"

    def _run_command_via_codex_cli(
        self,
        *,
        cwd: Path,
        command: str,
        codex_bin: str,
        codex_model: str | None,
        env: dict[str, str],
    ) -> tuple[int, str, str]:
        prompt = self._build_codex_exec_prompt(command)
        cmdline = [
            codex_bin,
            "exec",
            "--json",
            "--skip-git-repo-check",
            "-s",
            "workspace-write",
            "-C",
            str(cwd),
            "-c",
            f'reasoning.effort="{CODEX_EXEC_REASONING_EFFORT}"',
        ]
        if codex_model:
            cmdline.extend(["-m", codex_model])
        cmdline.append(prompt)

        proc = subprocess.run(
            cmdline,
            cwd=str(cwd),
            env=env,
            capture_output=True,
            text=True,
            timeout=600,
            check=False,
        )

        if proc.returncode != 0:
            stderr = ((proc.stderr or "") + "\n" + (proc.stdout or "")).strip() or "Codex CLI failed"
            if codex_model and is_codex_model_config_error(stderr):
                logger.warning(
                    "Codex execution model '%s' is incompatible; retrying command without explicit model",
                    codex_model,
                )
                if self.runtime_config_store is not None:
                    try:
                        self.runtime_config_store.update(codex_planner_model="")
                    except Exception:
                        logger.exception("Could not persist codex execution model reset")

                return self._run_command_via_codex_cli(
                    cwd=cwd,
                    command=command,
                    codex_bin=codex_bin,
                    codex_model=None,
                    env=env,
                )
            return proc.returncode, "", stderr

        return self._parse_codex_json_events(proc.stdout or "")

    def execute(self, context: ProjectContext, command: TaggedCommand) -> ExecutionResult:
        self._validate_command(command.cmd)
        runtime = self._runtime_config()

        worktree_path = self._resolve_worktree(context, command.worktree)
        cwd = self._resolve_cwd(context, command, worktree_path)

        if not cwd.exists() or not cwd.is_dir():
            raise CodexCommandError("Execution cwd does not exist")

        if not context.permission or context.permission.needs_sudo:
            raise CodexCommandError(
                "Project is not writable by current process. "
                "Grant folder permissions or launch with elevated privileges."
            )

        started_at = utc_now_iso()
        engine = "shell"
        runtime_cache_dir = context.stash_dir / "runtime-cache"
        uv_cache_dir = runtime_cache_dir / "uv"
        runtime_cache_dir.mkdir(parents=True, exist_ok=True)
        uv_cache_dir.mkdir(parents=True, exist_ok=True)

        exec_env = dict(os.environ)
        exec_env["UV_CACHE_DIR"] = str(uv_cache_dir)
        exec_env.setdefault("XDG_CACHE_HOME", str(runtime_cache_dir))
        venv_scripts = sysconfig.get_path("scripts")
        if venv_scripts:
            existing_path = exec_env.get("PATH", "")
            if existing_path:
                exec_env["PATH"] = f"{venv_scripts}{os.pathsep}{existing_path}"
            else:
                exec_env["PATH"] = venv_scripts
        venv_purelib = sysconfig.get_paths().get("purelib")
        if venv_purelib:
            existing_pythonpath = exec_env.get("PYTHONPATH", "")
            if existing_pythonpath:
                exec_env["PYTHONPATH"] = f"{venv_purelib}{os.pathsep}{existing_pythonpath}"
            else:
                exec_env["PYTHONPATH"] = str(venv_purelib)

        logger.info(
            "Executing command mode=%s worktree=%s cwd=%s cmd=%s",
            runtime.codex_mode,
            command.worktree or "default",
            str(cwd),
            command.cmd.replace("\n", " ")[:300],
        )

        try:
            if runtime.codex_mode == "cli":
                resolved_codex = resolve_binary(runtime.codex_bin)
                if not resolved_codex:
                    raise FileNotFoundError(runtime.codex_bin)
                exit_code, stdout, stderr = self._run_command_via_codex_cli(
                    cwd=cwd,
                    command=command.cmd,
                    codex_bin=resolved_codex,
                    codex_model=runtime.codex_planner_model,
                    env=exec_env,
                )
                engine = "codex-cli"
            else:
                exit_code, stdout, stderr = self._run_command_via_shell(cwd=cwd, command=command.cmd, env=exec_env)
                engine = "shell"
        except FileNotFoundError:
            if runtime.codex_mode == "cli":
                # Fallback keeps the pipeline functional when codex binary is missing.
                exit_code, stdout, shell_stderr = self._run_command_via_shell(cwd=cwd, command=command.cmd, env=exec_env)
                stderr = f"codex binary not found; executed via shell fallback\n{shell_stderr}"
                engine = "shell-fallback"
                logger.warning("Codex binary missing; used shell fallback")
            else:
                raise CodexCommandError("Execution binary not found")
        except subprocess.TimeoutExpired as exc:
            exit_code = 124
            stdout = (exc.stdout or "") if isinstance(exc.stdout, str) else ""
            stderr = "Command timed out after 600 seconds"
            logger.error("Command timed out after 600s")

        finished_at = utc_now_iso()
        logger.info("Execution finished engine=%s exit_code=%s", engine, exit_code)
        return ExecutionResult(
            engine=engine,
            exit_code=exit_code,
            stdout=stdout,
            stderr=stderr,
            started_at=started_at,
            finished_at=finished_at,
            cwd=str(cwd),
            worktree_path=str(worktree_path),
        )

    def execute_payload(self, context: ProjectContext, payload: str) -> list[ExecutionResult]:
        commands = parse_tagged_commands(payload)
        if not commands:
            raise CodexCommandError("No <codex_cmd> blocks were found")
        return [self.execute(context, command) for command in commands]
