---
description: Implement work in a DeepSeek subagent
agent: build
model: deepseek/deepseek-v4-flash
subtask: true
---

Implement the work described by the user, using the current session context and any spec, tickets, or request supplied below:

$ARGUMENTS

Load and follow the `tdd` skill where possible, at pre-agreed seams.

Run typechecking regularly, run focused tests regularly, and run the full test suite once at the end.

Once done, load and follow the `code-review` skill to review the work.

Commit the completed work only when the user explicitly requests a commit.
