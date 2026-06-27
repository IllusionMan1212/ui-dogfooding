Next on the list:-
- [x] Support SVGs or an easier way to add icons. Maybe just a font for the icons and we can use a png for the logo
    - Decided to go with TVGs instead for the icons. And a PNG for the logo.
    - [x] The svg to tvg converter sucks ass and converts these icons shittily. Annoying
        I want to try loading the tvgs in ladybird and seeing how they look. If they look the same then the converter sucks
        if not then my renderer sucks.
        Went with an icon font. This works best
- [x] Ability to change cursor (e.g. Hovering button, disabled button, etc..)
- [x] Text truncation (ellipsizing)
- [x] Scrollable areas
    - [x] Scrollbars should be clickable and draggable
- [x] Clipping?
- [ ] Supporting different mouse clicks
- [ ] Tooltips
    - Needs some heavy polish
    - [x] Need a way to attach this to other widgets
    - [x] Doesn't quite work properly right now.
    - [x] Should be drawn on a higher z-index (???) (not sure how this plays with overlays and dialogs)
    - [x] Hovering over something that has a tooltip will request infinite frames
        - [ ] Fixed but broke tooltips that follow the mouse
- [x] BUG: Cursor changing for the split only works if we have one split in the entire app
- [ ] We need to be able to support changing the language even if XSetLocaleModifiers doesn't work
- [ ] Auto focus URL field on new request tab
- [ ] Auto scroll the tabbar to the active tab (when creating a new one and when making it active) when it's out of view
- [ ] Ctrl + L for focusing URL field shortcut
    - Shortcuts in general need a good system
    - Need a way to isolate shortcuts for different components/UI

- BUGS:
    - [x] Opening a tab causes the sidebar's scrollbar to be unresponsive to mouse dragging.
    - [ ] Hovering over the sidebar tabs while having a collection/environment open causes the text size to leak to the open tab
    - [ ] Windows: Changing language with Alt + Shift doesn't seem to work (even when focus is on text input).
        - Probably a windows API that we have to call to tell the OS hey we're currently focused on a text input
    - [ ] We're able to scroll the sidebar when a dialog is open. That should be fixed.

- [ ] CJK and emoji fonts (at least the noto one) are very big, embedding that into the binary bloats up its size.
    We could either:-
    - Not support CJK fonts.
    - Load all fonts as a resource from the file system
    - Probe the system for fonts and use those
    Still haven't decided, but I will likely go with the first option for now, unless there's demand for them in the future.

- [ ] Closing unsaved tabs should prompt a dialog to save them

Pretty good ideas:-
- [ ] Wrap OpenGL calls in order to track memory usage and associate them with each "object" type (e.g. texture, buffer, etc..). This way we can track memory usage and detect leaks.
    - Very useful in the future.

- Tab Switcher:-
    - [ ] Need to limit the number of tabs shown in the tab switcher. 6 or 7
    - [ ] Quickly pressing ctrl + tab should not open the tab switcher. It should only open if you hold ctrl and press tab. (like firefox)
        - [ ] Tab switcher should be able to switch to the last tab when pressing ctrl + tab (like firefox)
    - [ ] Hovering an item in the switcher, and then navigating with the keyboard has a bug where we quickly switch to the keyboard selected item, then the mouse hover item on the first navigation.

Claude reviews:
- [ ] Importer/Exporter feature set(?) Have claude review them and see if we're missing values when importing/exporting.

- [ ] Importing and exporting doesn't show the toast message. We need to implement a fade animation for it.

- Big Refactors:-
    - [x] Move away from fixed buffers for names and everything else.
    - [x] Better lifetime grouping for memory allocations.

- UI:
    - [ ] We have to assert or something when the stack pushes and pops don't match up. A lot of times I forget to pop something or push something too many times and styles leak.
    - [x] Empty state for collections/environment sidebar
    - [ ] Migrate everything to use string builder with input limitations

- [x] Dialog
    - [ ] Text drawn in dialogs gets drawn at the default size on the first frame, then the correct size on the second+ frames.

- Text renderer
    - [ ] Anti-aliasing on the equals glyph is really bad.
    - [ ] Colored emojis are affected by the text color. They should be drawn as-is, without any color modification.
    - [ ] Should we anti-alias emojis? Seems to me like CBDT emojis already have anti-aliasing baked in, so we shouldn't need to do it again. But we should test this.
    - [ ] Modifiers in emojis (e.g. skin tone) don't work properly. The modifier is drawn as a separate glyph instead of modifying the base emoji glyph.
    - [ ] We currently rasterize emojis (at runtime) to a 2048x2048 texture atlas and therefore this means that we can only support a limited number of emojis. This texture is never cleared or overwritten, so if we use a lot of emojis then we will eventually run out of space in the texture atlas and therefore some emojis will be drawn as blank space.
        - Currently the emojis seem to be rasterized at 128px. We could try rasterizing them at a smaller size (e.g. 64px) to fit more emojis in the texture atlas. OR rasterize at the requested size.
        Few thoughts:-
        - If we decided to drop the atlas and somehow draw from vectors (are emojis even stored as vectors in the font?) then we could support infinite emojis AND get rid of the bitmap texture atlas. (Less VRAM)
        - If the above is not possible, then we would need a way to fit all possible, visible emojis in the texture atlas, which I'm not sure is possible either.
        - ??? No idea ??
        - So apparently it depends on the font. Some fonts have emojis as layers of vectors, others store various sized bitmaps (32x32, 64x64, 128x128, etc..).
            This is annoying. vectors seems like the best way but we should probably support both.
        - I guess our best bet for bitmap emojis is to rasterize them at the requested size and then cache them in a texture atlas. This way we can support infinite emojis, but we would need to clear the texture atlas when it gets full and re-rasterize the emojis that are currently visible.
- Font system
    - [x] Need a way to select different (registered) fonts at runtime for different text. I need this for monospace fonts.

Claude mentions a couple of things to consider:-
- The glyph cache key includes pixel_size (ui_text.odin:1031), so the same glyph re-tessellates and re-uploads per size. Storing curves in size-independent EM space and scaling in the shader would dedupe these — bigger refactor, real follow-up win.
    - This one seems interesting. But I'm very happy with the VRAM usage reductions we already did. So this is a nice to have but not a priority.
- The bitmap atlas (RGBA8 2048×2048 + mipmaps ≈ 21 MB, ui_text.odin:2067) for color/emoji glyphs is another VRAM chunk if you want to look there next.
    - This one I'm not sure about cause we likely need it for emojis (if we wanna use emojis)

- [x] Text input
    - [x] When moving the mouse, sometimes the blinking of the caret takes longer (This is something to do with how we handle events I bet)
    - [-] When window loses focus we should unfocus the text input (or at the very least stop wasting cpu blinking the caret)
        - Literally doesn't matter for now
    - [x] Caret should be customizable?
    - [x] Selection color should be customizable
    - [x] Placeholder color should be customizable
    - [x] Double click to select word is broken, only selects texts before caret position.
        - [x] It also doesn't stop word selection at standard places all other text editors support.
    - [x] Caret should have a white-ish color
    - [x] We should have a variant that just takes a strings.Builder instead of a buffer. Easier API for "infinite" text input
    - [x] The selection box doesn't seem to cover the entire text from the left side when scrolling occurs due to the text overflowing the text input box.
    - [x] Ctrl + left/right arrows should move by word bound, just like double click selection
    - [x] Double click to select word + hold should select words instead of individual letters
    - [x] Triple clicking should select whole line
    - [x] Triple click to select line + hold should select whole lines instead of individual letters or words

Misc:
- [ ] We should probably somehow generate the whole ui_push_* ui_pop_* ui_set_next_* procedures as well as their nodes.

Optimizations:-
- [x] Only rendering frames when something has visually changed
    - This one is becoming needed more and more as more text is drawn.
    - I think there's a different one where it divides the window to a grid and checks those for changes or something.
    - Added engine-side render-on-change mode with an explicit toggle so apps can keep continuous rendering when needed (e.g. 3D scenes/animations).
- [x] Clipping/Scissoring
- [x] Culling stuff that's under dialogs/whatever
- [ ] Texture atlas caching thing for images. Basically just prerender all used images in a single atlas texture
      so we can draw multiple images in one draw call.
