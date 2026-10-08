# UI Context

## Theme

[Describe the overall visual language — e.g. Dark only.
No light mode. The design language is a dark technical
workspace — near-black backgrounds, layered surfaces,
and vivid accent colors for interactive elements.]

## Colors

[Define your color tokens as CSS custom properties.
All components must use these tokens — no hardcoded
hex values.]

| Role            | CSS Variable       | Value    |
| --------------- | ------------------ | -------- |
| Page background | `--bg-base`        | `#[hex]` |
| Surface         | `--bg-surface`     | `#[hex]` |
| Primary text    | `--text-primary`   | `#[hex]` |
| Muted text      | `--text-muted`     | `#[hex]` |
| Primary accent  | `--accent-primary` | `#[hex]` |
| Border          | `--border-default` | `#[hex]` |
| Error           | `--state-error`    | `#[hex]` |
| Success         | `--state-success`  | `#[hex]` |

## Typography

| Role      | Font              | Variable      |
| --------- | ----------------- | ------------- |
| UI text   | [e.g. Geist Sans] | `--font-sans` |
| Code/mono | [e.g. Geist Mono] | `--font-mono` |

## Border Radius

| Context           | Class            |
| ----------------- | ---------------- |
| Inline / small UI | `rounded-[size]` |
| Cards / panels    | `rounded-[size]` |
| Modals / overlays | `rounded-[size]` |

## Component Library

[e.g. shadcn/ui on top of Tailwind. Components live
in components/ui/. Use the CLI to add new components
rather than writing from scratch.]

## Layout Patterns

- [Pattern — e.g. Editor: full-viewport split with
  left sidebar, center canvas, right sidebar]
- [Pattern — e.g. Sidebars: fixed width with border separator]
- [Pattern — e.g. Modals: centered overlay with backdrop blur]
- [Pattern — e.g. Navbar: top bar with bottom border]

## Icons

[e.g. Lucide React. Stroke-based icons only. Sizes:
h-4 w-4 for inline, h-5 w-5 for buttons.]

## Skills (UI / UX)

Use these installed skills when designing or implementing UI. They complement
`web-design-guidelines` and `shadcn` (Agent Skills) — do not replace them.

| Skill | When to use |
| ----- | ----------- |
| `ui-ux-pro-max` | Product/page UI reasoning, stack-aware patterns, UX guidelines; optional `search.py` (Python 3) for CSV design data |
| `brand` | Logo, voice, color/type identity, brand guideline sync |
| `design-system` | Tokens, component specs, Tailwind integration; hierarchical pages via `design-system/MASTER.md` when needed |
| `ui-styling` | Tailwind/shadcn theming, responsive utilities, canvas fonts |

**Persist → this file:** When a skill (or `--persist` / design-system output) produces tokens,
colors, typography, or component conventions, write the durable choices into
`context/ui-context.md` (project source of truth). Keep long hierarchical design
docs in `design-system/` only when the project needs multi-page token trees.
