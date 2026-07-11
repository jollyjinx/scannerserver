---
title: Repository Agent Instructions
description: Repository-wide working conventions for coding agents.
type: instructions
audience: agents
status: current
---

# Repository Agent Instructions

When a workflow or example refers to `docker`, use the `container` command instead; only if it requires use of options that are not available in container use docker instead.

When using Swift Packages where we do not have a skill for, create a skill for that package in the global skills so that in essence we have a skill then for each package in the future. prefix with the skill directory name with spm- so it becomes easily understandable. eg. https://github.com/jollyjinx/SFSymbolEnum becomes .agents/skills/spm-gh-jollyjnx-sfsymbolenum
