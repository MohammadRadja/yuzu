# Documentation instructions

## Scope

This directory documents the implemented Yuzu application and its explicitly proposed improvements. `ARCHITECTURE.md` describes source behavior, `DESIGN.md` describes current UI plus the design system, `DEVELOPMENT.md` describes supported workflows and validation limits, `SECURITY.md` records controls and open risks, and `SKILLS.md` records maintenance competencies.

## Writing rules

- Use professional technical English and concise Markdown.
- Describe implementation with source-file references such as `Sources/Radial/DragMonitor.swift`.
- Label proposals, limitations, and unverified behavior explicitly; do not turn intentions into claims.
- Use the product name Yuzu for current behavior. Mention Satsuma only for upstream attribution or migration context.
- Keep headings stable, use fenced code blocks for commands, and use Mermaid only for diagrams that reflect actual relationships.

## Source of truth

Code, `.brisk.toml`, CI workflows, tests, and scripts are authoritative for behavior and commands. Documentation must not override them. When a document conflicts with source, correct the document or change the implementation and update both.

## Update workflow

1. Inspect the affected implementation and tests.
2. Update the smallest relevant document set.
3. Check cross-references, counts, names, paths, and command examples.
4. Run available static checks and record unavailable validation in `DEVELOPMENT.md` or the handoff.

## Review checklist

- Are current behavior and future work clearly separated?
- Are security claims evidenced by code or configuration?
- Are source paths, bundle identifiers, tool names, and platform versions current?
- Are diagrams consistent with the source?
- Is Satsuma attribution and the MIT license preserved?
