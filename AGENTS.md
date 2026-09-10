# Active workspace

This task continues the Android 0.7.23 project in this directory:
`/Users/ok/felicity-dashboard`.

Read `docs/CLIENT_VERSIONS.md` for the three independent client versions and
`docs/ANDROID_ARCHIVE_HANDOFF.md` before continuing the archive bug fix.
PR #48 was merged into `main` on 2026-09-10. Its merge commit is
`bf10aa36fca366bc158645aae28eb32dab18f181`. Before that merge, `main` held a
different Android development state (0.15.1), while the archive client was
0.7.23 on `feature/ios-client`.

At the start of a repository task, inspect `pwd`, `git status --short --branch`,
and `git remote -v`; fetch origin and compare the checked-out commit with its
upstream before drawing conclusions about missing code. Preserve uncommitted
changes. Use task branches under `codex/`; use `main` as the integration branch.
Do not treat a local build output or a larger version number on another branch
as proof that its source is newer. Run `python3 tools/check_client_versions.py`
when changing client versions or firmware artifacts.

The previous ChatGPT project copy was imported on 2026-09-10, including its
uncommitted iOS changes and untracked Android files. Preserve those changes.
Use this workspace for subsequent edits and builds for this task. The old
copy is retained as a reference; do not overwrite it as part of this fix.
