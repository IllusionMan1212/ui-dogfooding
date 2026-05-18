package main

import "engine"
import "core:fmt"

ButtonSize :: enum {
    Small,
    Medium,
    Large,
}

IconButtonSize :: enum {
    ExtraSmall,
    Small,
    Medium,
    Large,
}

ButtonVariant :: enum {
    Primary,
    SecondaryGrey,
    SecondaryColored,
    TertiaryGrey,
    TertiaryColored,
    LinkGrey,
    LinkColored,
}

ICON :: enum {
    Settings,
    Environment,
    Folder,
    Check,
    Chevron,
    Close,
    Code,
    Copy,
    EmptyState,
    FolderAdd,
    History,
    LinkExternal,
    Lock,
    Plus,
    Search,
    ThreeDots,
    Warning,
}

ICONS := [ICON]string {
    .Settings = "\uE000",
    .Environment = "\uE001",
    .Folder = "\uE002",
    .Check = "\uE003",
    .Chevron = "\uE004",
    .Close = "\uE005",
    .Code = "\uE006",
    .Copy = "\uE007",
    .EmptyState = "\uE008",
    .FolderAdd = "\uE009",
    .History = "\uE00A",
    .LinkExternal = "\uE00B",
    .Lock = "\uE00C",
    .Plus = "\uE00D",
    .Search = "\uE00E",
    .ThreeDots = "\uE00F",
    .Warning = "\uE010",
}

SidebarTab :: enum {
    Collections,
    Environments,
    //History,
}

State :: struct {
    active_sidebar_tab: SidebarTab,
}

state: State
theme := Theme.Dark

BORDER_V :: #force_inline proc() {
    engine.ui_set_next_width(engine.ui_px(1, 1))
    engine.ui_set_next_height(engine.ui_fill())
    engine.ui_set_next_background_color(engine.color_hex_rgb(THEME_BORDER_PRIMARY_DEFAULT[theme]))
    engine.ui_set_next_flags({.DrawBackground})
    engine.ui_row()
}

BORDER_H :: #force_inline proc() {
    engine.ui_set_next_width(engine.ui_fill())
    engine.ui_set_next_height(engine.ui_px(1, 1))
    engine.ui_set_next_background_color(engine.color_hex_rgb(THEME_BORDER_PRIMARY_DEFAULT[theme]))
    engine.ui_set_next_flags({.DrawBackground})
    engine.ui_row()
}

draw_topbar :: proc() {
    engine.ui_set_next_width(engine.ui_fill())
    engine.ui_set_next_height(engine.ui_px(64, 1))
    engine.ui_set_next_background_color(engine.color_hex_rgb(THEME_BACKGROUND_SECONDARY_DEFAULT[theme]))
    engine.ui_set_next_flags({.DrawBackground})
    engine.ui_set_next_align_y(.Center)
    engine.ui_row(); {
        engine.ui_padding(18, {.Left, .Right}) 

        engine.ui_set_next_width(engine.ui_children_sum(0))
        engine.ui_set_next_height(engine.ui_fill())
        engine.ui_set_next_align_y(.Center)
        engine.ui_row(); {
            engine.ui_set_next_width(engine.ui_px(30, 1))
            engine.ui_set_next_height(engine.ui_px(30, 1))
            engine.ui_image(logo)
            engine.ui_spacer(engine.ui_px(10, 1))
            engine.ui_set_next_font_weight(THEME_FONT_WEIGHT_BODY)
            engine.ui_text_sized("Moonladder", 14)
        }

        engine.ui_spacer(engine.ui_px(24, 1))

        engine.ui_text_sized("Personal Workspace", 14)
        engine.ui_text_sized(ICONS[.Chevron], 16)

        engine.ui_spacer(engine.ui_percent(1, 0.05))
        if draw_icon_button(.Settings, engine.color_hex_rgb(THEME_ICON_SECONDARY_DEFAULT[theme]), size = .ExtraSmall, variant = .SecondaryGrey) {
            fmt.println("TODO: settings")
        }
    }
}

@require_results
draw_button :: proc(
    label: string,
    variant := ButtonVariant.Primary,
    size := ButtonSize.Medium,
    enabled := true,
    left_icon: Maybe(ICON) = nil,
    right_icon: Maybe(ICON) = nil,
) -> bool {
    variants_map := [ButtonVariant]struct {
        background_color: engine.Color,
        background_hover_color: engine.Color,
        background_disabled_color: engine.Color,
        border_color: engine.Color,
        border_disabled_color: engine.Color,
        text_color: engine.Color,
        text_hover_color: engine.Color,
        text_disabled_color: engine.Color,
    } {
        .Primary = {
            engine.color_hex_rgb(THEME_BACKGROUND_BRAND_SOLID),
            engine.color_hex_rgb(THEME_BACKGROUND_BRAND_SOLID_HOVER[theme]),
            engine.color_hex_rgb(THEME_BACKGROUND_PRIMARY_DISABLED[theme]),
            0x00,
            engine.color_hex_rgb(THEME_BORDER_PRIMARY_DEFAULT[theme]),
            engine.color_hex_rgb(THEME_TEXT_SECONDARY_INVERSE[theme]),
            engine.color_hex_rgb(THEME_TEXT_SECONDARY_INVERSE[theme]),
            engine.color_hex_rgb(THEME_TEXT_PRIMARY_DISABLED[theme]),
        },
        .SecondaryGrey = {
            engine.color_hex_rgb(THEME_BACKGROUND_PRIMARY_DEFAULT[theme]),
            engine.color_hex_rgb(THEME_BACKGROUND_SECONDARY_DEFAULT[theme]),
            engine.color_hex_rgb(THEME_BACKGROUND_PRIMARY_DISABLED[theme]),
            engine.color_hex_rgb(THEME_BORDER_PRIMARY_DEFAULT[theme]),
            engine.color_hex_rgb(THEME_BORDER_PRIMARY_DEFAULT[theme]),
            engine.color_hex_rgb(THEME_TEXT_SECONDARY_DEFAULT[theme]),
            engine.color_hex_rgb(THEME_TEXT_SECONDARY_HOVER[theme]),
            engine.color_hex_rgb(THEME_TEXT_PRIMARY_DISABLED[theme]),
        },
        .SecondaryColored = {
            engine.color_hex_rgb(THEME_BACKGROUND_PRIMARY_DEFAULT[theme]),
            engine.color_hex_rgb(THEME_BACKGROUND_BRAND_DEFAULT_HOVER[theme]),
            engine.color_hex_rgb(THEME_BACKGROUND_PRIMARY_DISABLED[theme]),
            engine.color_hex_rgb(THEME_BORDER_BRAND_DEFAULT),
            engine.color_hex_rgb(THEME_BORDER_PRIMARY_DEFAULT[theme]),
            engine.color_hex_rgb(THEME_TEXT_BRAND_DEFAULT[theme]),
            engine.color_hex_rgb(THEME_TEXT_BRAND_DEFAULT[theme]),
            engine.color_hex_rgb(THEME_TEXT_PRIMARY_DISABLED[theme]),
        },
        .TertiaryGrey = {
            0x00,
            engine.color_hex_rgb(THEME_BACKGROUND_SECONDARY_DEFAULT[theme]),
            0x00,
            0x00,
            0x00,
            engine.color_hex_rgb(THEME_TEXT_TERTIARY_DEFAULT[theme]),
            engine.color_hex_rgb(THEME_TEXT_SECONDARY_DEFAULT[theme]),
            engine.color_hex_rgb(THEME_TEXT_PRIMARY_DISABLED[theme]),
        },
        .TertiaryColored = {
            0x00,
            engine.color_hex_rgb(THEME_BACKGROUND_PRIMARY_DEFAULT_HOVER[theme]),
            0x00,
            0x00,
            0x00,
            engine.color_hex_rgb(THEME_TEXT_BRAND_DEFAULT[theme]),
            engine.color_hex_rgb(THEME_TEXT_BRAND_DEFAULT[theme]),
            engine.color_hex_rgb(THEME_TEXT_PRIMARY_DISABLED[theme]),
        },
        .LinkGrey = {
            0x00,
            0x00,
            0x00,
            0x00,
            0x00,
            engine.color_hex_rgb(THEME_TEXT_SECONDARY_DEFAULT[theme]),
            engine.color_hex_rgb(THEME_TEXT_SECONDARY_HOVER[theme]),
            engine.color_hex_rgb(THEME_TEXT_PRIMARY_DISABLED[theme]),
        },
        .LinkColored = {
            0x00,
            0x00,
            0x00,
            0x00,
            0x00,
            engine.color_hex_rgb(THEME_TEXT_BRAND_DEFAULT[theme]),
            engine.color_hex_rgb(THEME_TEXT_BRAND_HOVER[theme]),
            engine.color_hex_rgb(THEME_TEXT_SECONDARY_DISABLED),
        },
    }

    font_size_map := [ButtonSize]i32 {
        .Small = 14,
        .Medium = 16,
        .Large = 16,
    }
    padding_map := [ButtonSize][2]f32 {
        .Small = {14, 4},
        .Medium = {16, 10},
        .Large = {18, 10},
    }

    engine.ui_push_font_size(font_size_map[size])
    defer engine.ui_pop_font_size()
    style := engine.ui_button_style(
        variants_map[variant].background_color,
        variants_map[variant].background_hover_color,
        variants_map[variant].background_hover_color,
        variants_map[variant].background_disabled_color,
        variants_map[variant].border_color,
        variants_map[variant].border_color,
        variants_map[variant].border_color,
        variants_map[variant].border_disabled_color,
        variants_map[variant].text_color,
        variants_map[variant].text_hover_color,
        variants_map[variant].text_hover_color,
        variants_map[variant].text_disabled_color,
        THEME_BORDER_RADIUS_MD,
        0.5,
        variant == .LinkColored || variant == .LinkGrey ? 0 : padding_map[size].x,
        variant == .LinkColored || variant == .LinkGrey ? 0 : padding_map[size].y,
    )

    left_icon_text := ""
    if left_icon != nil {
        left_icon_text = ICONS[left_icon.?]
    }
    right_icon_text := ""
    if right_icon != nil {
        right_icon_text = ICONS[right_icon.?]
    }

    return engine.ui_button_styled_with_icons(label, style, left_icon = left_icon_text, right_icon = right_icon_text, enabled = enabled)
}

@require_results
draw_icon_button :: proc(
    icon: ICON,
    icon_color: Maybe(engine.Color) = nil,
    icon_size: i32 = 20,
    variant := ButtonVariant.Primary,
    size := IconButtonSize.Medium,
    enabled := true,
) -> bool {
    engine.ui_set_next_width(engine.ui_children_sum(1))
    engine.ui_set_next_height(engine.ui_children_sum(1))

    variants_map := [ButtonVariant]struct {
        background_color: engine.Color,
        background_hover_color: engine.Color,
        background_disabled_color: engine.Color,
        border_color: engine.Color,
        border_disabled_color: engine.Color,
        text_color: engine.Color,
        text_hover_color: engine.Color,
        text_disabled_color: engine.Color,
    } {
        .Primary = {
            engine.color_hex_rgb(THEME_BACKGROUND_BRAND_SOLID),
            engine.color_hex_rgb(THEME_BACKGROUND_BRAND_SOLID_HOVER[theme]),
            engine.color_hex_rgb(THEME_BACKGROUND_PRIMARY_DISABLED[theme]),
            0x00,
            engine.color_hex_rgb(THEME_BORDER_PRIMARY_DEFAULT[theme]),
            engine.color_hex_rgb(THEME_TEXT_SECONDARY_INVERSE[theme]),
            engine.color_hex_rgb(THEME_TEXT_SECONDARY_INVERSE[theme]),
            engine.color_hex_rgb(THEME_TEXT_PRIMARY_DISABLED[theme]),
        },
        .SecondaryGrey = {
            engine.color_hex_rgb(THEME_BACKGROUND_PRIMARY_DEFAULT[theme]),
            engine.color_hex_rgb(THEME_BACKGROUND_SECONDARY_DEFAULT[theme]),
            engine.color_hex_rgb(THEME_BACKGROUND_PRIMARY_DISABLED[theme]),
            engine.color_hex_rgb(THEME_BORDER_PRIMARY_DEFAULT[theme]),
            engine.color_hex_rgb(THEME_BORDER_PRIMARY_DEFAULT[theme]),
            engine.color_hex_rgb(THEME_TEXT_SECONDARY_DEFAULT[theme]),
            engine.color_hex_rgb(THEME_TEXT_SECONDARY_HOVER[theme]),
            engine.color_hex_rgb(THEME_TEXT_PRIMARY_DISABLED[theme]),
        },
        .SecondaryColored = {
            engine.color_hex_rgb(THEME_BACKGROUND_PRIMARY_DEFAULT[theme]),
            engine.color_hex_rgb(THEME_BACKGROUND_BRAND_DEFAULT_HOVER[theme]),
            engine.color_hex_rgb(THEME_BACKGROUND_PRIMARY_DISABLED[theme]),
            engine.color_hex_rgb(THEME_BORDER_BRAND_DEFAULT),
            engine.color_hex_rgb(THEME_BORDER_PRIMARY_DEFAULT[theme]),
            engine.color_hex_rgb(THEME_TEXT_BRAND_DEFAULT[theme]),
            engine.color_hex_rgb(THEME_TEXT_BRAND_DEFAULT[theme]),
            engine.color_hex_rgb(THEME_TEXT_PRIMARY_DISABLED[theme]),
        },
        .TertiaryGrey = {
            0x00,
            engine.color_hex_rgb(THEME_BACKGROUND_SECONDARY_DEFAULT[theme]),
            0x00,
            0x00,
            0x00,
            engine.color_hex_rgb(THEME_TEXT_TERTIARY_DEFAULT[theme]),
            engine.color_hex_rgb(THEME_TEXT_SECONDARY_DEFAULT[theme]),
            engine.color_hex_rgb(THEME_TEXT_PRIMARY_DISABLED[theme]),
        },
        .TertiaryColored = {
            0x00,
            engine.color_hex_rgb(THEME_BACKGROUND_PRIMARY_DEFAULT_HOVER[theme]),
            0x00,
            0x00,
            0x00,
            engine.color_hex_rgb(THEME_TEXT_BRAND_DEFAULT[theme]),
            engine.color_hex_rgb(THEME_TEXT_BRAND_DEFAULT[theme]),
            engine.color_hex_rgb(THEME_TEXT_PRIMARY_DISABLED[theme]),
        },
        .LinkGrey = {
            0x00,
            0x00,
            0x00,
            0x00,
            0x00,
            engine.color_hex_rgb(THEME_TEXT_SECONDARY_DEFAULT[theme]),
            engine.color_hex_rgb(THEME_TEXT_SECONDARY_HOVER[theme]),
            engine.color_hex_rgb(THEME_TEXT_PRIMARY_DISABLED[theme]),
        },
        .LinkColored = {
            0x00,
            0x00,
            0x00,
            0x00,
            0x00,
            engine.color_hex_rgb(THEME_TEXT_BRAND_DEFAULT[theme]),
            engine.color_hex_rgb(THEME_TEXT_BRAND_HOVER[theme]),
            engine.color_hex_rgb(THEME_TEXT_SECONDARY_DISABLED),
        },
    }

    padding_map := [IconButtonSize]f32 {
        .ExtraSmall = 6,
        .Small = 10,
        .Medium = 12,
        .Large = 14,
    }

    style := engine.ui_button_style(
        variants_map[variant].background_color,
        variants_map[variant].background_hover_color,
        variants_map[variant].background_hover_color,
        variants_map[variant].background_disabled_color,
        variants_map[variant].border_color,
        variants_map[variant].border_color,
        variants_map[variant].border_color,
        variants_map[variant].border_disabled_color,
        variants_map[variant].text_color,
        variants_map[variant].text_color,
        variants_map[variant].text_color,
        variants_map[variant].text_disabled_color,
        THEME_BORDER_RADIUS_MD,
        0.5,
        padding_map[size],
        padding_map[size],
    )

    engine.ui_push_font_size(icon_size)
    defer engine.ui_pop_font_size()
    return engine.ui_button_styled(ICONS[icon], style, enabled = enabled)
}

draw_collections_list :: proc() {
    engine.ui_set_next_width(engine.ui_fill())
    engine.ui_set_next_height(engine.ui_fill())
    engine.ui_column(); {
        engine.ui_padding(12, {.Left, .Right})

        {
            engine.ui_set_next_align_x(.End)
            engine.ui_set_next_align_y(.Center)
            engine.ui_set_next_width(engine.ui_fill())
            engine.ui_set_next_height(engine.ui_children_sum(1))
            engine.ui_row(); {
                if draw_button("New", .LinkColored, .Small, left_icon = .Plus) {
                    // TODO: new collection dialog
                }
                engine.ui_spacer(engine.ui_px(12, 1))
                if draw_button("Import", .LinkColored, .Small) {
                    // TODO: import
                }
            }
        }

        engine.ui_text("Collections")
    }
}

draw_environments_list :: proc() {
    engine.ui_set_next_width(engine.ui_fill())
    engine.ui_set_next_height(engine.ui_fill())
    engine.ui_column(); {
        engine.ui_text("Environments")
    }
}

draw_sidebar :: proc() {
    engine.ui_set_next_width(engine.ui_px(350, 1))
    engine.ui_set_next_height(engine.ui_fill())
    engine.ui_set_next_background_color(engine.color_hex_rgb(THEME_BACKGROUND_SECONDARY_DEFAULT[theme]))
    engine.ui_set_next_flags({.DrawBackground})
    engine.ui_row(); {
        engine.ui_padding(12, {.Top, .Bottom})
        {
            engine.ui_set_next_height(engine.ui_fill())
            engine.ui_set_next_width(engine.ui_children_sum(1))
            engine.ui_column(); { // Vertical Tabs
                engine.ui_padding(16, {.Left})
                engine.ui_padding(12, {.Right})

                if draw_icon_button(.Folder, engine.color_hex_rgb(state.active_sidebar_tab == .Collections ? THEME_BACKGROUND_PRIMARY_DEFAULT[theme] : THEME_ICON_SECONDARY_DEFAULT[theme]), size = .Small, variant = state.active_sidebar_tab == .Collections ? .Primary : .SecondaryGrey) {
                    state.active_sidebar_tab = .Collections
                }
                engine.ui_spacer(engine.ui_px(10, 1))
                if draw_icon_button(.Environment, engine.color_hex_rgb(state.active_sidebar_tab == .Environments ? THEME_BACKGROUND_PRIMARY_DEFAULT[theme] : THEME_ICON_SECONDARY_DEFAULT[theme]), size = .Small, variant = state.active_sidebar_tab == .Environments ? .Primary : .SecondaryGrey) {
                    state.active_sidebar_tab = .Environments
                }
            }
        }
        BORDER_V()
        switch state.active_sidebar_tab { // Content Area
        case .Collections:
            draw_collections_list()
        case .Environments:
            draw_environments_list()
        }
    }
}

draw_main_area :: proc() {
    engine.ui_text("Main Area")
}

folder: engine.TvgIcon
environment: engine.TvgIcon
logo: engine.TextureId
settings: engine.TvgIcon

main :: proc() {
    engine.init("", "Moonladder", {1000, 600}, false)
    ensure(engine.ui_text_register_font("res/fonts/RedHatDisplay.ttf"))
    ensure(engine.ui_text_register_font("res/fonts/icons.ttf"))
    // assert(engine.ui_text_register_font("res/fonts/NotoSansCJK-Regular.ttc"))
    // assert(engine.ui_text_register_font("res/fonts/NotoSansEgyptianHieroglyphs-Regular.ttf"))
    // assert(engine.ui_text_register_font("res/fonts/NotoColorEmoji.ttf"))
    // assert(engine.ui_text_register_font("res/fonts/lucide-font/lucide.ttf"))
    engine.ui_text_set_default_pixel_size(20)
    engine.set_clear_color(engine.color_hex_rgb(THEME_BACKGROUND_SECONDARY_DEFAULT[theme]))
    engine.set_msaa(.NONE)

    logo = engine.load_texture(#load("./res/icons/moonladder.png"), false, true)

    icon, ok := engine.tvg_icon_load(#load("./res/icons/folder.tvg"))
    ensure(ok)
    folder = icon
    icon, ok = engine.tvg_icon_load(#load("./res/icons/environment.tvg"))
    ensure(ok)
    environment = icon
    icon, ok = engine.tvg_icon_load(#load("./res/icons/settings.tvg"))
    ensure(ok)
    settings = icon

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
                    engine.set_clear_color(engine.color_hex_rgb(THEME_BACKGROUND_SECONDARY_DEFAULT[theme]))
                }
            }

            e = engine.iter_events()
        }

        window_size := engine.get_window_size()

        engine.ui_begin_build(window_size)
        engine.ui_text_set_default_pixel_size(16)
        engine.ui_text_set_default_font_weight(THEME_FONT_WEIGHT_BODY)
        {
            engine.ui_set_next_width(engine.ui_fill())
            engine.ui_set_next_height(engine.ui_fill())
            engine.ui_set_next_background_color(engine.color_hex_rgb(THEME_BACKGROUND_PRIMARY_DEFAULT[theme]))
            engine.ui_set_next_flags({.DrawBackground})
            engine.ui_column(); {
                engine.ui_push_text_color(engine.color_hex_rgb(THEME_TEXT_PRIMARY_DEFAULT[theme]))
                defer engine.ui_pop_text_color()

                draw_topbar()
                BORDER_H()
                engine.ui_set_next_width(engine.ui_fill())
                engine.ui_set_next_height(engine.ui_fill())
                engine.ui_row(); {
                    draw_sidebar()
                    BORDER_V()
                    draw_main_area()
                }
            }
        }
        engine.ui_end_build()

        engine.ui_draw(engine.get_projection())

        engine.frame_end()
    }
    engine.deinit()
}
