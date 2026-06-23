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

## Popup

### Popup (Widget)
: A reusable immediate-mode popup widget (`ui_popup_begin` / `ui_popup_end`) that renders a floating container anchored to another widget. The popup positions itself below the anchor (left-aligned), flipping above if insufficient space below, and pushes left if off-screen right.

### Popup Backdrop
: A full-screen transparent `MouseClickable` box rendered behind the popup container. Clicks on the backdrop are detected by the engine in the next frame and cause the popup to close. The popup container itself is `MouseClickable` to absorb clicks on empty space within the popup, preventing them from reaching the backdrop.

### Popup Open State
: Stored in the engine as `popup_open_id` (an `Id`). The app signals the engine to open a popup via `ui_popup_open(id)` (called from a button click handler) and closes it via `ui_popup_close()` (called from a content item click handler). The engine also auto-closes on backdrop click.

### Popup Root
: A root-level floating box (`popup_root`) created alongside `tooltip_root` in `ui_begin_build`. All popup containers are children of `popup_root`. In `ui_end_build`, `popup_root` is moved to the end of the root's children (before `tooltip_root`) so popups draw above standard content but below tooltips.

## Visual Properties

### Brand Color
Teal/green `#16BAA4`. Defined as `THEME_BORDER_BRAND_DEFAULT` and `THEME_BACKGROUND_BRAND_SOLID` in `theme.odin`. Used for the splitter's hover state.

## Memory & Lifetimes

### Ownership model
Every persistent entity and everything it transitively owns lives on the **default heap** (`context.allocator`). There are no model-specific arenas — the old `state.collection_allocator` is gone. The rules:

- Exactly one `create_*` and one `destroy_*` per entity. `destroy_*` frees **precisely** what was allocated, so a single call fully reclaims an entity.
- Every reassignment of an owned `string` is **delete-then-clone** (`delete(x.name); x.name = strings.clone(new)`), never clone-only. This is the pattern behind `rename_workspace`/`rename_collection`; cloning without deleting is a leak.

| Entity | Stored as | Owns (heap) | Destroy |
|---|---|---|---|
| Workspace | `state.workspaces: [dynamic]Workspace` | `name`, `collections`, `environments` | `destroy_workspace` |
| Collection | `Workspace.collections: [dynamic]^Collection` (stable ptrs) + tree links | `name`, `requests`, nested request data | `destroy_collection` |
| Request | value in `collection.requests`, or `new(Request)` for standalone tabs | url/body/response builders, `query_params`, `headers`, `path_params`, `body.structured[].file_paths`, `body.binary_path` | `destroy_request` |
| Environment | `Workspace.environments: [dynamic]^Environment` (stable ptrs) | `variables` | `destroy_environment` |

### All entity text is `string` (no fixed buffers)
Every text field on the model is a heap `string` — names, all `Authorization` fields, `RequestHeader`/`QueryParam`/`FormField`/`PathParam` key/value/content_type, and `EnvironmentVariableField` variable/value. There are no `[N]u8` buffers. Each owned string is delete-then-clone on edit and freed by its `destroy_*`. `Authorization` is embedded by value in both `Request` and `Collection`, so copying it with a plain `=` from another **live** auth aliases the string pointers (double-free risk) — use `clone_authorization` to copy and `destroy_authorization` to free (a freshly-built auth, e.g. from `parse_postman_auth`, is fine to assign since it owns its strings). The custom JSON marshallers write these via a single `case string:`; unmarshallers and the importer `strings.clone` into them; read sites use the field directly, and the curl/C boundary uses `strings.clone_to_cstring`.

### Stable pointers, not interior pointers
`state.tabs` (`^Request`/`^Collection`/`^Environment`) and `state.active_environment` hold raw pointers, so the entities they reference must be **individually heap-allocated** (`new`) and stored as pointer-slices — never as interior pointers into a `[dynamic]Value` array, which reallocates on append and shifts on `ordered_remove`. Collections and environments are both `[dynamic]^T`. Requests opened from a collection are copy-on-open into their own `new(Request)` (the tab owns its copy and has `is_modified`); collections/environments are edited live (no `is_modified` flag).

### Detach before free
Before freeing an entity that a tab can reference, detach the tab first: `detach_collection_tabs` (orphans request tabs as unsaved, closes collection tabs across the subtree) and `detach_environment_tabs` (closes env tabs, clears `active_environment`). `delete_collection` and `delete_workspace` do this, then call the `destroy_*` teardown. Moving an environment between workspaces does **not** detach — the heap pointer stays valid, so the tab follows the environment.
