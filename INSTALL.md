# Installation

This skill is distributed as a directory. Install it by symlinking (or copying) it into your agent CLI's skill directory.

## Canonical layout

Keep one canonical copy, for example:

```bash
git clone <this-repo> ~/.ai-skills/swarm/skills/frappe-multihand
# or
cp -R ./frappe-multihand ~/.ai-skills/swarm/skills/frappe-multihand
```

Then symlink it into each agent's skill directory.

## Per-agent symlink commands

Replace `SRC` with the path to your canonical copy.

### Kimi Code

```bash
SRC="$HOME/.ai-skills/swarm/skills/frappe-multihand"
ln -sfn "$SRC" "$HOME/.kimi-code/skills/frappe-multihand"
```

### Claude Code

```bash
SRC="$HOME/.ai-skills/swarm/skills/frappe-multihand"
ln -sfn "$SRC" "$HOME/.claude/skills/frappe-multihand"
```

### Cursor

```bash
SRC="$HOME/.ai-skills/swarm/skills/frappe-multihand"
ln -sfn "$SRC" "$HOME/.cursor/skills/frappe-multihand"
```

### OpenCode

```bash
SRC="$HOME/.ai-skills/swarm/skills/frappe-multihand"
ln -sfn "$SRC" "$HOME/.opencode/skills/frappe-multihand"
ln -sfn "$SRC" "$HOME/.config/opencode/skills/frappe-multihand"
```

### Codex

```bash
SRC="$HOME/.ai-skills/swarm/skills/frappe-multihand"
ln -sfn "$SRC" "$HOME/.codex/skills/frappe-multihand"
```

### Antigravity (agy)

```bash
SRC="$HOME/.ai-skills/swarm/skills/frappe-multihand"
ln -sfn "$SRC" "$HOME/.gemini/config/skills/frappe-multihand"
ln -sfn "$SRC" "$HOME/.ai-skills/antigravity/skills/frappe-multihand"
```

### Pi

```bash
SRC="$HOME/.ai-skills/swarm/skills/frappe-multihand"
ln -sfn "$SRC" "$HOME/.pi/agent/skills/frappe-multihand"
ln -sfn "$SRC" "$HOME/.pi/skills/frappe-multihand"
```

### OpenClaw

```bash
SRC="$HOME/.ai-skills/swarm/skills/frappe-multihand"
ln -sfn "$SRC" "$HOME/.kimi_openclaw/workspace/skills/frappe-multihand"
```

## One-liner for all agents

```bash
SRC="$HOME/.ai-skills/swarm/skills/frappe-multihand"
for dst in \
  "$HOME/.kimi-code/skills/frappe-multihand" \
  "$HOME/.claude/skills/frappe-multihand" \
  "$HOME/.cursor/skills/frappe-multihand" \
  "$HOME/.agents/skills/frappe-multihand" \
  "$HOME/.opencode/skills/frappe-multihand" \
  "$HOME/.config/opencode/skills/frappe-multihand" \
  "$HOME/.codex/skills/frappe-multihand" \
  "$HOME/.gemini/config/skills/frappe-multihand" \
  "$HOME/.ai-skills/antigravity/skills/frappe-multihand" \
  "$HOME/.pi/agent/skills/frappe-multihand" \
  "$HOME/.pi/skills/frappe-multihand" \
  "$HOME/.kimi_openclaw/workspace/skills/frappe-multihand"; do
  mkdir -p "$(dirname "$dst")"
  ln -sfn "$SRC" "$dst"
done
```

## Verification

After installing, ask your agent:

> "What is the frappe-multihand skill?"

It should respond with the description from `SKILL.md`.

## Uninstall

Remove the symlinks; the canonical copy stays intact.

```bash
rm -f "$HOME/.kimi-code/skills/frappe-multihand"
# ... repeat for other agents
```
