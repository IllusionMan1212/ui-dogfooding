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

- Big Refactors:-
    - [ ] Move away from fixed buffers for names and everything else.
    - [ ] Better lifetime grouping for memory allocations.

- UI:
    - [ ] We have to assert or something when the stack pushes and pops don't match up. A lot of times I forget to pop something or push something too many times and styles leak.

- [x] Dialog
    - [ ] Text drawn in dialogs gets drawn at the default size on the first frame, then the correct size on the second+ frames.

- Text renderer
    - [ ] Anti-aliasing on the equals glyph is really bad.

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

- [ ] Empty state for collections/environment sidebar
- [ ] Migrate everything to use string builder with input limitations

Optimizations:-
- [x] Only rendering frames when something has visually changed
    - This one is becoming needed more and more as more text is drawn.
    - I think there's a different one where it divides the window to a grid and checks those for changes or something.
    - Added engine-side render-on-change mode with an explicit toggle so apps can keep continuous rendering when needed (e.g. 3D scenes/animations).
- [x] Clipping/Scissoring
- [x] Culling stuff that's under dialogs/whatever
- [ ] Texture atlas caching thing for images. Basically just prerender all used images in a single atlas texture
      so we can draw multiple images in one draw call.
