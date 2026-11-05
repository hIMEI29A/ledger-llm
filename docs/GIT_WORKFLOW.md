
# Git Workflow

This document defines the Git workflow and conventions that AI agents must follow when working on this project.

## Branching

- Always start a new task branch from the `main` branch.
- Create a feature branch using the following naming template:  
  
```text  
<type>/<description>  
  
Where:  
- `<type>` — one of the supported prefixes listed below.  
- `<description>` — a short, kebab-case description of the work.  
```

### General naming rules  
  
- Use lowercase alphanumerics, hyphens (`-`), and dots (`.` only for version numbers).  
- Do not use uppercase letters, underscores, spaces, or special characters.  
- Avoid consecutive, leading, or trailing hyphens or dots.  
- Keep names clear and concise.  
- Include a ticket/issue number if applicable. 

### Purpose prefixes (for any contributor, including AI agents)  
  
| Prefix | Alias | Use for |  
|---|---|---|  
| `feature/` | `feat/` | New features or enhancements |  
| `bugfix/` | `fix/` | Bug fixes |  
| `hotfix/` | — | Urgent production fixes |  
| `release/` | — | Release preparation (dots allowed in version, e.g. `release/v1.2.0`) |  
| `chore/` | — | Maintenance, dependencies, documentation updates |  
| `refactor/` | — | Code improvements without behavior changes |  
| `docs/` | — | Documentation-only changes |  
| `test/` | — | Test additions or modifications |  

- If the work is linked to an issue, include the issue number in the description:  
  
```text
`<type>/issue-<number>-<kebab-case-description>`

Where:  
- `<type>` — one of the supported prefixes listed below. 
- `<number>` - issue number
- `<description>` — a short, kebab-case description of the work.  
```

**Examples:**  
  
- `refactor/fix-login-validation`  
- `test/issue-42-add-export-button`  
- `test/chatgpt/update-dependencies` 

## Commits

- Use a brief, single-line commit message.
- Keep the message focused and descriptive. Do not write multi-line or verbose commit messages.
  
## Pull Requests

- If the PR closes an issue, begin the PR description with:Closes: #[issue-number]
- Provide a concise overview of the problem and the changes made. Avoid boilerplate text.
- Check the list of available labels in the repository and suggest the most appropriate ones. Always ask the user to confirm the suggested labels before applying them.
- If the branch was created from a branch other than `main`, set the PR base branch accordingly (do not default to `main`).

## Issues

- When creating or commenting on an issue, clearly note that the content was produced in collaboration with an AI agent.

Example: `Generated with OpenCode`

