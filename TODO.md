Next on the list:-
- [x] Support SVGs or an easier way to add icons. Maybe just a font for the icons and we can use a png for the logo
    - Decided to go with TVGs instead for the icons. And a PNG for the logo.
    - [x] The svg to tvg converter sucks ass and converts these icons shittily. Annoying
        I want to try loading the tvgs in ladybird and seeing how they look. If they look the same then the converter sucks
        if not then my renderer sucks.
        Went with an icon font. This works best
- [ ] We should probably somehow generate the whole ui_push_* ui_pop_* ui_set_next_* procedures as well as their nodes.
- [ ] Ability to change cursor (e.g. Hovering button, disabled button, etc..)

Optimizations:-
- [ ] Only rendering frames when something has visually changed
- [ ] Clipping/Scissoring
- [ ] Culling stuff that's under dialogs/whatever
- [ ] Texture atlas caching thing for images. Basically just prerender all used images in a single atlas texture
      so we can draw multiple images in one draw call.
