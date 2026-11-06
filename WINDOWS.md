# Running dsh-superagent on Windows

Upstream is written for POSIX hosts: the launcher uses Python's `fcntl`, `ps` and
`tmux`, the setup probes run commands as `<env> PATH=… <cli> …`, and the worker
shims call `/bin/sh`. This branch is the set of changes that got it running on
Windows 11 against the desktop build of DSH.

It is a record of one working setup, not a supported port. Only two files under
`src/` change — everything else is scripts and this note.

## What was verified

On dsh `0.2.1-rc.2` with Node 24 and Git for Windows:

- the plugin loads, `setup: ok`, the panel and the management API answer;
- a GitHub Source polls the repository and reports `0 notifications`;
- a ticket runs end to end — worker session, clone, edit, push, pull request —
  both for a comment-triggered change to an existing file and for an
  issue-body-triggered new file.

Feishu was not enabled, so its Source is untested here.

## Install

```bat
npm i -g @deepseek-ai/dsh@0.2.1-rc.3
git clone https://github.com/deepseek-ai/dsh-superagent-prototype
cd dsh-superagent-prototype
pnpm install
pnpm build
dsh superagent --from-default-profile web --dump-config > nul
dsh plugin --profile superagent add "link:%CD%"
```

Then edit `%DSH_HOME%\profiles\superagent\cordis.patch.yml`:

```yaml
- id: webserver
  config:
    host: 127.0.0.1
    port: 3082

- id: dsh-superagent
  config:
    # The two fixes below are what allow this form; upstream's schema demands a
    # leading "/" and DSH refuses that on Windows. See "Fix 1".
    stateDir: C:/dsh-superagent-state
```

`%DSH_HOME%` is `%APPDATA%\dsh-desktop\harness` for the desktop build. Do not
install this profile into the one you use day to day: it sets `PATH`,
`GH_CONFIG_DIR` and a GitHub credential helper for the whole process.

Start it with `scripts\win\dsh-superagent.ps1 start`, then open the panel with
`scripts\win\open-panel.cmd`.

## Fix 1 — a state directory cannot be both valid and absolute

`src/deployment.ts` validates `stateDir` with `pattern(/^\//)`, so a Windows path
is rejected. The rule has a real reason behind it: DSH's workspace service
(`fullyQualifiedWorkspacePath` in `dsh-workspace/lib/index.js`) treats `/` and `\`
as invalid roots on win32 and requires a drive-letter root. The two rules cannot
hold for the same string, so a Windows install has to name
`C:/dsh-superagent-state` — exactly what upstream's schema forbids:

```
TypeError: Workspace path is not fully qualified: '/dsh-superagent-state'
```

The fix widens the schema to accept `C:/…` as well:

```ts
- const absolute = (description: string) => s.string().pattern(/^\//)
+ const absolute = (description: string) =>
+   s.string().pattern(/^(?:\/|[A-Za-z]:[\\/])/)
```

## Fix 2 — the restricted tool list names `bash`

`src/app/sessions.ts` restricts a worker session to
`['skill', 'bash', 'read', 'read_image', 'job_output', 'job_list', 'job_kill']`.
On a Windows host the shell tool is registered as `pwsh`, so the call throws and
no ticket can start:

```
tools.restrict() names unknown global tool "bash";
known global tools: job_kill, job_list, job_output, pwsh, read, read_image, skill, working_directory
```

The same file special-cases `bash` when it decides whether a tool call should not
block, so that check has to accept both names. The fix picks the registered name
from `process.platform`.

## Traps that are not source bugs

| Symptom | Cause | What to do |
| --- | --- | --- |
| `The agent GitHub CLI cannot read its account. spawn env ENOENT` | The setup probe runs `<env> PATH=… <cli>`, and Windows has no `env.exe` | Put Git for Windows' `usr\bin` on `PATH` (`run-superagent.cmd` does) |
| `dsh: profile "superagent" does not exist` | Started outside the desktop app, so `DSH_HOME` is not inherited | Set `DSH_HOME` in the launcher |
| Every `@` instruction is ignored; `setup.accounts.agent` shows *your* account | Triggers whose actor is the agent account are dropped on purpose | Run the service as a second account (below) |
| A restart keeps using the previous `GH_CONFIG_DIR` / `DSH_HOME` | The listener was re-exec'd by the launcher `cmd.exe`, which still holds the old environment | Stop the launcher, not just the node process (`dsh-superagent.ps1 stop` does) |
| `Error: Lock file is already being held` right after a force-kill | `proper-lockfile` leaves `<stateDir>.lock` and treats it as held for 30 s (`src/app/runtime.ts:93`) | Wait 30 s, then start again |
| The panel URL stops working after a restart | The URL carries that run's auth token | Read the current URL from the log (`dsh-superagent.ps1 url`), never bookmark it |

## It takes two GitHub accounts

This is not a configuration choice. `src/sources/github-trigger.ts:63` marks a
trigger `human: isHumanLogin(user.login) && !sameName(user.login, agent)`, and
`src/core/model.ts:76` returns nothing for a trigger that is not human. An account
cannot instruct itself, so the account that writes `@agent do this` must differ
from the account the plugin runs as.

The setup that was verified:

1. An agent account, logged into its own gh config directory:
   `GH_CONFIG_DIR=C:\dsh-superagent-state\gh-config gh auth login`
   (device flow — the code must be entered in a session signed in as the agent,
   not as you).
2. Your own account invites the agent as a collaborator with push access, and the
   agent accepts the invitation.
3. On the panel (or `PUT /orchestrator/api/settings/policy`), allow your own login
   to give instructions: `sources.github.allowed: [{ id: "<your login>" }]`.
4. `GH_CONFIG_DIR` goes into the launcher, so the service, every worker it spawns
   and the git credential helper all act as the agent.

Wrapping `gh` in a `.cmd` shim instead of using `GH_CONFIG_DIR` does not work:
Node cannot spawn a `.cmd` without `shell: true`, and the setup probe fails.

## The scripts

- `scripts\win\dsh-superagent.ps1` — `start | stop | restart | status | url | log`.
  Starts the profile through `Win32_Process.Create` so the service outlives the
  terminal and any job object it lives in, and manages it by its listening port.
- `scripts\win\run-superagent.cmd` — the environment the profile needs
  (`DSH_HOME`, optional `GH_CONFIG_DIR`, `PATH`) and the log redirection.
  Created through WMI, it does not inherit variables set only in your shell: set
  overrides as user environment variables, or edit the file.
- `scripts\win\open-panel.cmd` — resolves the current panel URL and opens it.

One gotcha if you write your own script: `$pid` is a read-only automatic variable
in PowerShell, and assigning to it throws
`SessionStateUnauthorizedAccessException: VariableNotWritable` — silently, if the
error is not terminating, which is how a stop action can appear to succeed and do
nothing. Use another name.

## Limits

- The execution chain is still POSIX-flavoured: worker shims and credential
  helpers expect `sh` and a colon-separated `PATH`. They work with Git for
  Windows' `usr\bin`; they were not tested without it, and they are the part most
  likely to break on a future release.
- There is no Windows service. The process is started detached through WMI and
  does not restart after a reboot until you run `start` again.
- Upstream calls this a research prototype for reference only, not an official
  product. This branch does not change that.
