# unifi-diag - tmux-agents integration

This directory contains tmux-agents-specific additions. Original scripts are untouched.

## Setup

```bash
# From ~/tmux-agents/:
make unifi-diag-setup       # SSH key + router alias config
make unifi-diag-status      # Check SSH connectivity + deps
make unifi-diag-update      # Pull upstream changes
```

## PTM Skill

`skill-prompt.md` is the source of truth for the `unifi-diag` PTM skill. When the skill
prompt needs updating, edit this file and sync via Claude with ptm-mcp in RW mode.

Skill: `@prorated444/unifi-diag`

## Paths (when installed as submodule)

- Scripts: `~/tmux-agents/tools/unifi-diag/scripts/`
- Captures: `~/tmux-agents/tools/unifi-diag/captures/`
- Summaries: `~/tmux-agents/tools/unifi-diag/summaries/`
- Network map: `~/tmux-agents/tools/unifi-diag/docs/network_map.md`

## Upstream

Colin1374/unifi-diag on GitHub. Our `tmux-agents` branch adds only this directory.
Suggestions back upstream go as PRs from this branch.
