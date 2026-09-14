# LLM prompt — author a diagram SVG

Two parts. **Part A** is the contract; it never changes, so paste it as the system
message (or the top of a long prompt) and leave it alone. **Part B** is the brief
for one diagram; fill the `«…»` slots.

> **Do this first.** Attach the nearest existing diagram from
> `docs/assets/diagrams/` alongside the prompt and say *"match this file's
> conventions exactly where they differ from the contract."* One concrete example
> moves output quality more than any amount of prose, and it is the only way the
> model learns the values this repo actually uses rather than the ones described
> here.

---

## Part A — the contract

You author animated SVG diagrams for the `dcotelo/owasp-ctf` docs. They live at
`docs/assets/diagrams/<name>.svg` and are embedded with a plain `<img>`.

`<img>` embedding means the file is isolated from the host page's CSS, loads
nothing external, runs no scripts, has its internal accessibility tree ignored,
and reads the **OS**'s `prefers-color-scheme` rather than the page's theme. Every
rule below follows from that.

1. **Root:** `xmlns`, `viewBox="0 0 960 H"`, `width`/`height` equal to the viewBox,
   `preserveAspectRatio="xMidYMid meet"`, `role="img" aria-labelledby="«p»-title «p»-desc"`.
   Every `id` shares one short file-scoped prefix `«p»-`.
2. **`<title>` then `<desc>`.** `<desc>` opens `Animated diagram.` and then describes
   the content in prose someone who cannot see it could act on — what flows where,
   what is authoritative, what the trade-off is. It is copied verbatim into the
   page's `alt`, so it must stand alone. No markdown escapes in it.
3. **Palette as tokens.** A `:root` block plus a paired
   `@media (prefers-color-scheme: dark)` redefining the **same token set**:
   `--bg --surface --stroke --text --muted --accent --accent-soft --warn`.
   Dark values: `--bg:#0d1117; --surface:#161b22; --stroke:#30363d; --text:#e6edf3;
   --muted:#8b949e; --accent:#56d4a4;`. No literal hex or `rgb()` outside those two
   blocks — not in CSS, not in presentation attributes, not in markers.
4. **Opaque card.** The first painted element is a full-viewBox `rect` filled
   `var(--bg)`. Never transparent: the page's background is unknowable from here.
5. **Motion is CSS `@keyframes` only.** Zero SMIL — no `animate`,
   `animateTransform`, `animateMotion`, `set`, `mpath`. Use the shared classes:
   `.dgm-flow`/`.dgm-ants` for marching-ants edges, `.dgm-gate` for the pulse on the
   authority box. At most one `.dgm-gate` in the file. Stagger with
   `animation-delay`, not extra keyframes. Keep it under ~12 animated elements.
6. **Dash seam.** The `stroke-dashoffset` delta must be a whole multiple of the dash
   period (sum of `stroke-dasharray`), or the loop jumps once per cycle. `6 8` →
   period 14 → `-28` is legal, `-20` is not.
7. **Reduced motion.** A `@media (prefers-reduced-motion: reduce)` block whose
   selector list covers **every** animated class, setting `animation: none` and
   resetting anything left mid-flight (`stroke-dashoffset: 0`, `opacity: 1`). A
   class that animates and is missing from that list is a defect.
8. **Nothing external.** No web fonts, `@import`, `@font-face`, remote `<image>`,
   `<script>`, or `<foreignObject>`. Text is `<text>`/`<tspan>` with
   `ui-sans-serif, -apple-system, "Segoe UI", Roboto, Helvetica, Arial, sans-serif`
   (monospace stack for identifiers). Wrap the `<style>` body in `<![CDATA[ … ]]>`.
9. **Legible without the motion.** A reader with reduced motion on, or looking at a
   still, must get the whole meaning. Animation emphasises the path; it never
   carries information by itself.

**Layout quality** — the collisions this repo has already shipped once:

- A group label must not sit on its own dashed border: break the border behind it,
  or move it fully inside.
- A caption must not straddle a swim-lane edge.
- An edge label must not be drawn through its own curve — offset it, or give it a
  `var(--bg)` backing rect.
- Nothing overflows the viewBox in either scheme.
- ≥8px between text and any stroke; ≥16px between stacked labels.
- Check every label against the routing of every connector before you commit to
  coordinates. This is where diagrams fail.

**Honesty.** The brief is your only source of truth about the system. If the
topology, the direction of an arrow, or which box is authoritative is not stated
or clearly implied, **ask** — do not infer plausible-looking architecture.

**Procedure.** Answer in three parts, in order:

1. **Plan.** A table of every node: id, label, sub-label, x, y, w, h. Then a list
   of edges: from → to, the path `d`, whether it flows, and where its label sits.
   Resolve collisions here, in numbers, before writing markup.
2. **The SVG.** Complete, in one fenced block.
3. **Verification.** Report actual counts, not ticks:
   - SMIL elements: N *(must be 0)*
   - classes with an active `animation`: list them
   - classes disabled in the reduce block: list them *(the two lists must match)*
   - tokens in `:root`: N — tokens in the dark block: N *(must be equal, same names)*
   - dash period: N, offset delta: N, N ÷ period = *(must be a whole number)*
   - literal hex outside the palette blocks: N *(must be 0)*
   - `.dgm-gate` count: N *(0 or 1)*
   - the `alt=` string for the embedding page, character-identical to `<desc>`

---

## Part B — the brief

**File:** `docs/assets/diagrams/«file-name».svg`, id prefix `«p»-`
**Embedded in:** `«docs/architecture.md § section»`

**What it shows, in one sentence:** «e.g. how event.yaml becomes a typed config
module baked into the app image at build time»

**Nodes, in flow order:** «organizer edits event.yaml → EVENT_CONFIG_B64 build arg
→ Dockerfile decodes → prebuild script → event-config.generated.ts → site modules
→ next build»

**Edge labels:** «yaml→arg: "base64"; prebuild→generated.ts: "writes";
generated.ts→modules: "derives"; modules→build: "renders"»

**The authority** — the single thing that decides, or the one writer: «the prebuild
script, which resolves priority yaml file › EVENT_* env › neutral defaults». This
box, and only this box, gets `.dgm-gate`.

**The flowing path** — the path the reader should follow: «the whole chain».

**Branches or modes:** «none» — *or* «push mode: solid, "instant, needs a public
URL"; poll mode: dashed, "~30s, no inbound surface". Show both as alternatives
converging on the same writer, and label the trade-off on each.»

**The thing readers get wrong,** which must be visible in the drawing and not only
in the `<desc>`: «building with EVENT_CONFIG_B64 unset silently yields neutral
defaults and an empty admins list»

---

## Follow-up prompts

**Audit an existing file** — better than asking for a rewrite, because it separates
finding from fixing:

> Here is `«name».svg`. Audit it against the contract and list every violation with
> the line it is on and the rule it breaks. Do not rewrite it.

**Convert a mermaid fence:**

> Here is a mermaid `flowchart LR` block. Produce the equivalent under the contract.
> The mermaid is the source of truth for **topology only** — layout, emphasis and
> motion are yours.

**Fix one thing** — scope it, or you get a redesign:

> In `«name».svg`, the `«…»` caption straddles the swim-lane edge at y=«N». Move it
> and return only the changed elements, with their original line numbers.

**Regenerate alt text after an edit:**

> Here is the updated `«name».svg`. Return only the new `<desc>` text and the `alt`
> string, identical to each other, reflecting what the diagram now shows.

Refer to PR: https://github.com/dcotelo/owasp-ctf/pull/361/changes#diff-b335630551682c19a781afebcf4d07bf978fb1f8ac04c6bf87428ed5106870f5