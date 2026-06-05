# Moonladder — Domain Glossary

Text Input Widget
: Reusable UI control for editing user-provided text.

Single-Line Text Input
: Text input widget constrained to one logical line of text.

Focused Text Input
: Text input widget currently owning keyboard text-edit interaction.

Explicit Widget ID
: Caller-provided stable identifier required for stateful immediate-mode widgets whose state must persist across frames and repeated callsites.

Word Character
: A character forming part of a word boundary. In this codebase, letters (a-z, A-Z), digits (0-9), underscore (_), and all non-ASCII multi-byte characters are word characters. ASCII punctuation (.,;:!?()-[]{}"') is not, enabling standard word-select behavior at punctuation boundaries.

## Layout & Navigation

### Split Divider
A reusable immediate-mode widget (`ui_split_divider`) that creates a draggable handle between two panels. It replaces the static `BORDER_V` line. The widget returns two boxes: an **interactive** box (for signal/hit detection, width = `hit_thickness`) and a **visual** box (the visible 1px line, centered within the hit area, drawn with `DrawBackground`).

### Splitter Axis Convention
- `axis = .Y`: vertical divider line (tall, thin), panels are in a **row** (left/right), cursor = `HRESIZE`, drag direction = left/right
- `axis = .X`: horizontal divider line (wide, thin), panels are in a **column** (top/bottom), cursor = `VRESIZE`, drag direction = up/down

### Hit Area
The invisible interactive region (`hit_thickness` pixels wide) around the splitter's visual line. The visual line is centered within this hit area. Both `visual_thickness` and `hit_thickness` are configurable parameters.

## Visual Properties

### Brand Color
Teal/green `#16BAA4`. Defined as `THEME_BORDER_BRAND_DEFAULT` and `THEME_BACKGROUND_BRAND_SOLID` in `theme.odin`. Used for the splitter's hover state.
