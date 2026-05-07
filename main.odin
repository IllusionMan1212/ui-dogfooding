package main

import "engine"
import gl "vendor:OpenGL"

main :: proc() {
    engine.init("", "Moonladder", {1000, 600}, false)
    assert(engine.ui_text_register_font("res/fonts/RedHatDisplay.ttf"))
    // assert(engine.ui_text_register_font("res/fonts/NotoSansCJK-Regular.ttc"))
    // assert(engine.ui_text_register_font("res/fonts/NotoSansEgyptianHieroglyphs-Regular.ttf"))
    // assert(engine.ui_text_register_font("res/fonts/NotoColorEmoji.ttf"))
    // assert(engine.ui_text_register_font("res/fonts/lucide-font/lucide.ttf"))
    engine.ui_text_set_default_pixel_size(20)
    engine.set_clear_color({0, 0, 0, 1})
    engine.set_msaa(.NONE)

    theme := Theme.Light

    gl.Disable(gl.DEPTH_TEST)

    for !engine.should_quit() {
        engine.frame_start()

        e := engine.iter_events()
        for e != nil {
            #partial switch e.type {
                case .WINDOW_CLOSED:
                engine.quit()
                case .VIRT_KEY_PRESSED:
                if e.key.scancode == .T {
                    // state.screenshot = true
                    theme = theme == .Light ? .Dark : .Light
                }
            }

            e = engine.iter_events()
        }

        window_size := engine.get_window_size()

        engine.ui_begin_build(window_size)
        engine.ui_text_set_default_pixel_size(16)
        {engine.ui_set_next_width(engine.ui_percent(1, 1)); engine.ui_set_next_height(engine.ui_percent(1, 1)); engine.ui_set_next_background_color(engine.color_hex_rgb(THEME_BACKGROUND_PRIMARY_DEFAULT[theme])); engine.ui_set_next_flags({.DrawBackground}); engine.ui_column()
            {engine.ui_set_next_width(engine.ui_percent(1, 1)); engine.ui_set_next_height(engine.ui_px(65, 1)); engine.ui_set_next_background_color(engine.color_hex_rgb(THEME_BACKGROUND_SECONDARY_DEFAULT[theme])); engine.ui_set_next_flags({.DrawBackground}); engine.ui_set_next_align_y(.Center); engine.ui_row()
                engine.ui_padding(engine.ui_px(32, 1)) 
                engine.ui_push_text_color(engine.color_hex_rgb(THEME_TEXT_PRIMARY_DEFAULT[theme]))
                engine.ui_text_sized("Moonladder", 14)
            } // Top bar
            {engine.ui_set_next_width(engine.ui_percent(1, 1)); engine.ui_set_next_height(engine.ui_px(1, 1)); engine.ui_set_next_background_color(engine.color_hex_rgb(THEME_BORDER_PRIMARY_DEFAULT[theme])); engine.ui_set_next_flags({.DrawBackground}); engine.ui_row()}
            {engine.ui_set_next_width(engine.ui_percent(1, 1)); engine.ui_set_next_height(engine.ui_percent(1, 1)); engine.ui_row()
                {engine.ui_set_next_height(engine.ui_percent(1, 1)); engine.ui_set_next_background_color(engine.color_hex_rgb(THEME_BACKGROUND_SECONDARY_DEFAULT[theme])); engine.ui_set_next_flags({.DrawBackground}); engine.ui_row()
                    engine.ui_text("Sidebar")
                } // Sidebar
                {engine.ui_set_next_width(engine.ui_px(1, 1)); engine.ui_set_next_height(engine.ui_percent(1, 1)); engine.ui_set_next_background_color(engine.color_hex_rgb(THEME_BORDER_PRIMARY_DEFAULT[theme])); engine.ui_set_next_flags({.DrawBackground}); engine.ui_column()}
                {
                    engine.ui_text("Main Area")
                } // Main area
            } // Remaining
        }
        engine.ui_end_build()

        engine.ui_draw(engine.get_projection())

        engine.frame_end()
    }
    engine.deinit()
}
