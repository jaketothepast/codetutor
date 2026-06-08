# Initial Behavior Spec

## Startup

When the user opens CodeTutor for a project, the package opens a right-side panel and starts a session. The tutor reads project context from the project root, including `PROJECT.md`, `Project.md`, `project.md`, `spec/`, and architecture memory.

The startup response should tell the user where to begin, what to learn first, and which engineering judgment matters before writing code.

## Save Review

Before a file is saved, CodeTutor captures the on-disk file. After the save completes, it computes a unified diff from the previous on-disk content to the saved buffer content.

The tutor receives that diff and responds as a teaching pair programmer. It should focus on concepts, risks, architecture, tests, and a concrete next move.

## Manual Prompt

The user can run a minibuffer prompt. The tutor receives the current file context, project context, architecture memory, tree-sitter or imenu outline, and project file index.

The backend may inspect other files with read-only tools when available.

## What Next

The user can ask what to do next. The tutor should inspect/search context as needed and recommend one best next step, including why it matters and what concept the user should learn while doing it.

## Architecture Memory

The tutor may include durable architecture observations in a `codetutor-memory` fenced block. CodeTutor appends new memory lines to `.codetutor/ARCHITECTURE.md`.

The memory file is the only project file CodeTutor writes automatically.
