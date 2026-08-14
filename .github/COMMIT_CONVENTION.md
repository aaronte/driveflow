# Commit Convention

Use conventional commit prefixes. Format: `type: lowercase description`

## Prefixes

- `feat:` - new feature or capability
- `fix:` - bug fix or correction
- `style:` - visual/UI/CSS-only changes (no logic change)
- `refactor:` - code restructuring without behavior change
- `docs:` - documentation only
- `chore:` - build, config, deps, tooling
- `perf:` - performance improvement
- `test:` - adding or updating tests

## Rules

- **One commit per related task.** Group only files that share the same goal; split unrelated changes into separate commits (in dependency order when needed). Avoid monolithic commits that mix features, copy, and refactors.
- Description starts lowercase after the prefix
- No period at the end of the subject line
- Subject line under **72 characters**
- **State why the commit exists**, not only what changed. Prefer motivation, problem, or outcome in the subject (what tradeoff or failure mode drove this?). A subject that only lists mechanics (“add X”, “update Y”) should be rewritten to include *why* unless the prefix + scope already imply it.
- Optional **body** (after a blank line): more context—what was broken, what you measured, links, or follow-ups. Use when the subject cannot carry enough “why” in 72 characters.

## Examples (why-forward subjects)

- `feat: add PostHog so we can trace RN vs web funnels in one project`
- `fix: align bundle ID with App Store listing to unblock TestFlight`
- `style: enlarge demo hero so the value prop reads on small laptops`
- `docs: sync README with current env vars after the API rename`

## Example with body

```
fix: repair truncated 24p story JSON in eval

Golden scenarios were ending mid-object at max_tokens; extra repair
pass + higher ceiling gives the model room to finish valid JSON.
```
