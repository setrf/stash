from __future__ import annotations

import re
import shlex
import subprocess
from pathlib import Path

from .config import Settings
from .types import ExecutionResult, ProjectContext, TaggedCommand
from .utils import ensure_inside, stable_slug, utc_now_iso

TAG_RE = re.compile(r"<codex_cmd>(.*?)</codex_cmd>", flags=re.DOTALL | re.IGNORECASE)

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
    def __init__(self, settings: Settings):
        self.settings = settings

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
                target = (worktree_path / raw).resolve()
        else:
            target = worktree_path.resolve()

        if ensure_inside(context.root_path, target) or ensure_inside(worktree_path, target):
            target.mkdir(parents=True, exist_ok=True)
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

    def execute(self, context: ProjectContext, command: TaggedCommand) -> ExecutionResult:
        self._validate_command(command.cmd)

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

        if self.settings.codex_mode == "cli":
            cmdline = [self.settings.codex_bin, "exec", "--cwd", str(cwd), command.cmd]
            engine = "codex-cli"
        else:
            cmdline = ["bash", "-lc", command.cmd]
            engine = "shell"

        try:
            proc = subprocess.run(
                cmdline,
                cwd=str(cwd),
                capture_output=True,
                text=True,
                timeout=600,
                check=False,
            )
            exit_code = int(proc.returncode)
            stdout = proc.stdout
            stderr = proc.stderr
        except FileNotFoundError:
            if self.settings.codex_mode == "cli":
                # Fallback keeps the pipeline functional when codex binary is missing.
                proc = subprocess.run(
                    ["bash", "-lc", command.cmd],
                    cwd=str(cwd),
                    capture_output=True,
                    text=True,
                    timeout=600,
                    check=False,
                )
                exit_code = int(proc.returncode)
                stdout = proc.stdout
                stderr = f"codex binary not found; executed via shell fallback\n{proc.stderr}"
                engine = "shell-fallback"
            else:
                raise CodexCommandError("Execution binary not found")
        except subprocess.TimeoutExpired as exc:
            exit_code = 124
            stdout = (exc.stdout or "") if isinstance(exc.stdout, str) else ""
            stderr = "Command timed out after 600 seconds"

        finished_at = utc_now_iso()
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
