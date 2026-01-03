# Best Practices for Using Streamix with Antigravity (agy)

This project is configured to work seamlessly with AI-powered IDEs like Google Antigravity.

## 1. The Brain: `.cursorrules`
A `.cursorrules` file has been added to the project root. This file contains the "System Instructions" for the AI agents. It ensures that every time you ask for help, the agent knows:
- We use Elixir/Phoenix.
- We use `Req` for HTTP.
- We follow specific directory structures.

**Tip:** If you change a major architectural decision (e.g., switching HTTP clients), update `.cursorrules`.

## 2. Context Awareness
When working in Antigravity:
- **Reference Files:** Explicitly mention files or folders using the IDE's context features (often `@Filename` or by having the file open).
- **Project Map:** The agent can see the file structure, but for deep changes, point it to `GEMINI.md` or specific modules in `lib/streamix/`.

## 3. Workflow for New Features
1.  **Plan First**: Create a markdown file (e.g., `docs/plans/feature_name.md`) outlining what you want to build.
2.  **Ask the Agent**: Open that plan and ask the agent: "Implement the feature described in this file."
3.  **Review**: The agent will follow the conventions in `.cursorrules`.

## 4. Troubleshooting
If the agent writes non-idiomatic Elixir (e.g., using `HTTPoison` instead of `Req`):
- Remind it: "Read `.cursorrules` again."
- Update `.cursorrules` to be more explicit about the forbidden pattern.
