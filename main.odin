package main

import "core:hash"
import "base:runtime"
import "core:fmt"
import "core:os"
import "core:log"
import "core:strings"
import "core:math"
import "core:math/rand"
import "core:io"
import "core:mem"
import "core:mem/virtual"
import "core:reflect"
import "core:thread"
import "core:encoding/json"
import "core:hash/xxhash"
import "core:encoding/base64"

import "vendor:curl"

import "engine"

import "vendor/sentry"

RELEASE_BUILD :: #config(RELEASE_BUILD, false)
VERSION :: #config(VERSION, "")
GIT_SHA :: #config(GIT_SHA, "debug")

TOPBAR_HEIGHT :: 64
TABBAR_HEIGHT :: 40
TRANSPARENT :: 0x00000000

WorkspacesSchemaVersion :: enum int {
    V0 = 0,
    V1 = 1,
    V2 = 2,
}

CURRENT_WORKSPACES_SCHEMA_VERSION :: WorkspacesSchemaVersion.V2
CONFIG_DIR :: "moonladder" when RELEASE_BUILD else "moonladder-dev"
SENTRY_DSN :: "https://cab98e601501e6eb8bc4ba16edc9b07e@o4511034657144832.ingest.de.sentry.io/4511034682638416"

when RELEASE_BUILD {
	#assert(GIT_SHA != "debug")
	#assert(VERSION != "")
}

HttpMethod :: enum {
	Get,
	Post,
	Delete,
	Patch,
	Put,
	Head,
	Connect,
	Options,
	Trace,
}

http_method_strings := [?]string{"GET", "POST", "DELETE", "PATCH", "PUT", "HEAD", "CONNECT", "OPTIONS", "TRACE"}
body_type_strings := [?]string{"None", "Text", "JSON", "HTML", "XML", "multipart/form-data", "x-www-form-urlencoded", "File"}

http_method_string :: proc(m: HttpMethod) -> string #no_bounds_check {
	if m < .Get || m > .Trace { return "" }
	return http_method_strings[m]
}

body_type_string :: proc(b: BodyType) -> string #no_bounds_check {
    if b < .None || b > .File { return "" }
    return body_type_strings[b]
}

http_method_color :: #force_inline proc(m: HttpMethod) -> engine.Color {
    #partial switch m {
    case .Get:     return engine.color_hex_rgb(METHOD_GET)
    case .Post:    return engine.color_hex_rgb(METHOD_POST)
    case .Put:     return engine.color_hex_rgb(METHOD_PUT)
    case .Patch:   return engine.color_hex_rgb(METHOD_PATCH)
    case .Delete:  return engine.color_hex_rgb(METHOD_DELETE)
    case .Head:    return engine.color_hex_rgb(METHOD_HEAD)
    }
    return engine.color_hex_rgb(THEME_TEXT_INFO_DEFAULT[state.config.theme])
}

BodyType :: enum {
    None,
    Text,
    JSON,
    HTML,
    XML,
    Form,
    X_WWW_Form_Urlencoded,
    File,
}

AuthType :: enum {
    InheritFromParent,
    NoAuth,
    Basic,
    Token,
    ApiKey,
}

ApiKeyAddTo :: enum {
    Header,
    QueryParam,
}

TabType :: enum {
    Request,
    Collection,
    Environment,
}

TabItem :: union {
    ^Request,
    ^Collection,
    ^Environment,
}

#assert(size_of(Authorization) == 2960)
Authorization :: struct {
    type:          AuthType,
    basic_username: [128]u8  `fmt:"s,"`,
    basic_password: [512]u8  `fmt:"s,"`,
    bearer_token:   [1024]u8 `fmt:"s,"`,
    bearer_prefix:  [128]u8  `fmt:"s,"`,
    api_key_key:    [128]u8  `fmt:"s,"`,
    api_key_value:  [1024]u8 `fmt:"s,"`,
    api_key_add_to: ApiKeyAddTo,
}

FormField :: struct {
    id: i64,
    key: [512]u8 `fmt:"s,"`,
    value: [1024]u8 `fmt:"s,"`,
    file_paths: [dynamic]string,
    disabled: bool,
    is_file: bool, // Only used for form-data.
    content_type: [128]u8 `fmt:"s,"`, // Only used for form-data.
}

#assert(size_of(RequestBody) == 104)
RequestBody :: struct {
    type: BodyType,
    text: strings.Builder,
    structured: [dynamic]FormField,
    binary_path: string,
}

#assert(size_of(RequestHeader) == 1552)
RequestHeader :: struct {
    id: i64,
    key: [512]u8 `fmt:"s,"`,
    value: [1024]u8 `fmt:"s,"`,
    disabled: bool,
}

ResponseHeader :: struct {
    key: string,
    value: string,
}

// 4xx and 5xx status codes are considered a successful response too, the error status is only set if
// the request fails with a curl error.
RequestStatus :: enum {
    Initial,
    Running,
    Success,
    Error,
}

RequestOptionsTab :: enum {
    Parameters,
    Body,
    Authorization,
    Headers,
}

RequestResponseTab :: enum {
    Pretty,
    Body,
    Headers,
}

#assert(size_of(QueryParam) == 1552)
QueryParam :: struct {
    id: i64,
    key: [512]u8 `fmt:"s"`,
    value: [1024]u8 `fmt:"s"`,
    disabled: bool,
}

PathParamIndex :: struct {
    start: int,
    end: int,
}

#assert(size_of(PathParam) == 1064)
PathParam :: struct {
    indices: [dynamic]PathParamIndex,
    value: [1024]u8 `fmt:"s,"`,
}

#assert(size_of(Response) == 232)
Response :: struct {
    status_code: u16,
    time: struct {
        total: curl.off_t, // In microseconds
    },
    size: curl.off_t,
    data: strings.Builder,
    pretty_data: strings.Builder,
    raw_data: strings.Builder,
    raw_pretty_data: strings.Builder,
    has_escaped_unicode: bool,
    show_escaped_unicode: bool,
    headers: [dynamic]ResponseHeader,
}

// #assert(size_of(Request) == 7648) // TODO: Update after adding tab_type field
Request :: struct {
    id: i64, // 8
    name: [128]u8 `fmt:"s,"`, // 128
    method: HttpMethod, // 8
    url: [4096]u8 `fmt:"s,"`, // 4096
    body: RequestBody, // 104
    query_params: [dynamic]QueryParam, // 40
    path_params: map[string]PathParam, // 32
    headers: [dynamic]RequestHeader, // 40
    auth: Authorization, // 2832
    collection: ^Collection `json:"collection_id"`, // nil if standalone request. 8
    modification_hash: u128 `json:"-"`, // 16

    // Ephemeral
    is_modified: bool `json:"-"`, // 8
    curl_handle: ^curl.CURL `json:"-"`, // 8
    curl_headers: ^curl.slist `json:"-"`, // 8
    form: ^curl.mime `json:"-"`, // 8
    status: RequestStatus `json:"-"`, // 8
    response: Response `json:"-"`, // 232

    // Ephemeral UI state for this open request tab.
    active_options_tab: RequestOptionsTab `json:"-"`, // 8
    active_response_tab: RequestResponseTab `json:"-"`, // 8
    query_params_bulk_edit: bool `json:"-"`,
    headers_bulk_edit: bool `json:"-"`,
    height: f32 `json:"-"`,
}

Collection :: struct {
    id: i64,
    name: [128]u8 `fmt:"s,"`,
    requests: [dynamic]Request,
    auth: Authorization,
    parent: ^Collection `json:"-"`,
    first: ^Collection `json:"-"`,
    last: ^Collection `json:"-"`,
    next: ^Collection `json:"-"`,
    prev: ^Collection `json:"-"`,
    is_expanded: bool `json:"-"`,
}

EnvironmentVariableField :: struct {
    variable: [128]u8 `json:"variable"`,
    value: [1024]u8 `json:"value"`,
    enabled: bool `json:"enabled"`,
}

Environment :: struct {
    id: i64,
    name: [128]u8 `fmt:"s,"`,
    variables: [dynamic]EnvironmentVariableField,
}

Workspace :: struct {
    id: i64,
    name: [128]u8 `fmt:"s,"`,
    collections: [dynamic]^Collection,
    environments: [dynamic]Environment,
    selected_environment_id: i64 `json:"selected_environment_id"`,
}

@(deprecated="CollectionsFile is only used for migrating old workspace files that had collections at the root. Once v1.0.0 is released, we can remove this and the migration code.")
CollectionsFile :: struct {
    schema_version: int `json:"schema_version"`,
    collections: [dynamic]^Collection `json:"collections"`,
}

WorkspacesFile :: struct {
    schema_version: int `json:"schema_version"`,
    active_workspace_id: i64 `json:"active_workspace_id"`,
    workspaces: [dynamic]Workspace `json:"workspaces"`,
}

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

TextInputSize :: enum {
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

AccessToken :: distinct string

ServerInstance :: struct {
    name: string `json:"name"`,
    host: string `json:"host"`,
    port: string `json:"port"`,
    access_token: AccessToken `json:"access_token"`,
    user_email: string `json:"user_email"`,
}

Config :: struct {
    version: int `json:"cfg_version"`,
    instances: [dynamic]ServerInstance `json:"instances"`,
    active_instance: Maybe(ServerInstance) `json:"active_instance"`,
    timeout_ms: int `json:"timeout_ms"`,
    follow_redirects: bool `json:"follow_redirects"`,

    theme: Theme `json:"theme"`,
    sidebar_width: f32 `json:"sidebar_width"`,
    sidebar_tab: SidebarTab `json:"sidebar_tab"`,
}

State :: struct {
    config: Config,
    tabs: [dynamic]TabItem `qt:"property=tabs,read_slot=get_tabs"`,
    workspaces: [dynamic]Workspace,
    active_workspace_index: int,
    active_environment: ^Environment,
    collection_arena: virtual.Arena,
    collection_allocator: mem.Allocator,

    hasher: ^xxhash.XXH3_state `fmt:"-"`,

    curl_multi_handle: ^curl.CURLM,

    // UI
    active_tab_index: int,
    show_ui_debug_overlay: bool,
    ui_debug_overlay_pos: [2]f32,
    ui_debug_overlay_pos_initialized: bool,
    ui_debug_overlay_drag_offset: [2]f32,
    ui_debug_overlay_drag_start_mouse: [2]f32,
    ui_debug_overlay_drag_start_pos: [2]f32,
}

logger: log.Logger
state: State
logo: engine.TextureId

SCROLLBAR_V :: proc(scroll_box: ^engine.Box) {
    engine.ui_set_next_width(engine.ui_px(6, 1))
    engine.ui_set_next_height(engine.ui_fill())
    scrollbar := engine.ui_scrollbar_y_for(scroll_box)
    scrollbar.background_color = {0,0,0,0}
    scrollbar.border_color = engine.color_hex_rgb(THEME_BORDER_PRIMARY_DEFAULT[state.config.theme])
    scrollbar.border_radius = THEME_BORDER_RADIUS_MD
}

BORDER_V :: #force_inline proc() {
    engine.ui_set_next_width(engine.ui_px(1, 1))
    engine.ui_set_next_height(engine.ui_fill())
    engine.ui_set_next_background_color(engine.color_hex_rgb(THEME_BORDER_PRIMARY_DEFAULT[state.config.theme]))
    engine.ui_set_next_flags({.DrawBackground})
    engine.ui_row()
}

BORDER_H :: #force_inline proc() {
    engine.ui_set_next_width(engine.ui_fill())
    engine.ui_set_next_height(engine.ui_px(1, 1))
    engine.ui_set_next_background_color(engine.color_hex_rgb(THEME_BORDER_PRIMARY_DEFAULT[state.config.theme]))
    engine.ui_set_next_flags({.DrawBackground})
    engine.ui_row()
}

draw_topbar :: proc() {
    engine.ui_set_next_width(engine.ui_fill())
    engine.ui_set_next_height(engine.ui_px(TOPBAR_HEIGHT, 1))
    engine.ui_set_next_background_color(engine.color_hex_rgb(THEME_BACKGROUND_SECONDARY_DEFAULT[state.config.theme]))
    engine.ui_set_next_flags({.DrawBackground})
    engine.ui_set_next_align_y(.Center)
    engine.ui_row(); {
        engine.ui_padding(18, {.Left, .Right}) 

        engine.ui_set_next_width(engine.ui_children_sum(0))
        engine.ui_set_next_height(engine.ui_fill())
        engine.ui_set_next_align_y(.Center)
        engine.ui_row(); { // Logo and name
            engine.ui_set_next_width(engine.ui_px(30, 1))
            engine.ui_set_next_height(engine.ui_px(30, 1))
            engine.ui_image(logo)
            engine.ui_spacer(engine.ui_px(10, 1))
            engine.ui_set_next_font_weight(THEME_FONT_WEIGHT_BODY)
            engine.ui_text_sized("Moonladder", 14)
        }

        engine.ui_spacer(engine.ui_px(24, 1))

        workspace_selector_id := engine.ui_make_id("workspace_selector")
        workspace_selector_box: ^engine.Box

        {
            engine.ui_set_next_background_color(engine.color_hex_rgb(THEME_BACKGROUND_PRIMARY_DEFAULT[state.config.theme]))
            engine.ui_set_next_align_y(.Center)
            engine.ui_set_next_flags({.DrawBackground, .DrawBorder, .MouseClickable})
            engine.ui_set_next_width(engine.ui_children_sum(1))
            engine.ui_set_next_height(engine.ui_children_sum(1))
            engine.ui_set_next_border_thickness(0.5)
            engine.ui_set_next_border_color(engine.color_hex_rgb(THEME_BORDER_PRIMARY_DEFAULT[state.config.theme]))
            engine.ui_set_next_border_radius(THEME_BORDER_RADIUS_MD)
            workspace_selector_box = engine.ui_row(); {
                engine.ui_padding(6, {.Top, .Bottom})
                engine.ui_padding(12, {.Left, .Right})

                engine.ui_push_text_color(engine.color_hex_rgb(THEME_TEXT_SECONDARY_DEFAULT[state.config.theme]))
                defer engine.ui_pop_text_color()
                engine.ui_text_sized(string(cstring(&state.workspaces[state.active_workspace_index].name[0])), 14)
                engine.ui_spacer(engine.ui_px(12, 1))
                engine.ui_text_sized(ICONS[.Chevron], 16)
            }
            sig := engine.ui_signal_from_box(workspace_selector_box)

            if engine.ui_hovering(sig) {
                engine.set_cursor(.HAND)
                workspace_selector_box.background_color = engine.color_hex_rgb(THEME_BACKGROUND_PRIMARY_DEFAULT_HOVER[state.config.theme])
            }

            if engine.ui_clicked(sig) {
                engine.ui_popup_open(workspace_selector_id)
            }
        }

        // Workspace selector popup
        {
            min_width := f32(200)
            engine.ui_set_next_flags({.DrawBackground, .DrawBorder})
            engine.ui_set_next_background_color(engine.color_hex_rgb(THEME_BACKGROUND_PRIMARY_DEFAULT_ALT[state.config.theme]))
            engine.ui_set_next_border_thickness(0.5)
            engine.ui_set_next_border_color(engine.color_hex_rgb(THEME_BORDER_PRIMARY_DEFAULT[state.config.theme]))
            engine.ui_set_next_border_radius(THEME_BORDER_RADIUS_MD)
            if engine.ui_popup_begin(workspace_selector_id, workspace_selector_box) {
                engine.ui_set_next_width(engine.ui_px(225, 1))
                engine.ui_set_next_height(engine.ui_children_sum(1))
                engine.ui_set_next_align_x(.Center)
                engine.ui_column(); {
                    engine.ui_padding(THEME_SPACING_SM, {.Top, .Bottom, .Left, .Right})

                    for &workspace, i in state.workspaces {
                        if i != 0 {
                            engine.ui_spacer(engine.ui_px(6, 1))
                        }

                        name := string(cstring(&workspace.name[0]))
                        is_active := i == state.active_workspace_index

                        engine.ui_set_next_width(engine.ui_fill())
                        engine.ui_set_next_height(engine.ui_children_sum(1))
                        engine.ui_set_next_flags({.DrawBackground, .MouseClickable})
                        engine.ui_set_next_align_y(.Center)
                        engine.ui_set_next_border_radius(THEME_BORDER_RADIUS_MD)

                        id := engine.ui_make_id(fmt.tprintf("workspace_%d", workspace.id))

                        item_box := engine.ui_row(id); {
                            item_sig := engine.ui_signal_from_box(item_box)

                            if engine.ui_hovering(item_sig) {
                                engine.set_cursor(.HAND)
                                item_box.background_color = engine.color_hex_rgb(THEME_BACKGROUND_PRIMARY_DEFAULT_HOVER[state.config.theme])
                            } else {
                                item_box.background_color = TRANSPARENT
                            }

                            engine.ui_padding(THEME_SPACING_XS, {.Top, .Bottom})
                            engine.ui_padding(THEME_SPACING_SM, {.Left, .Right})

                            if i == 0 {
                                engine.ui_text(ICONS[.Lock])
                            } else {
                                engine.ui_spacer(engine.ui_px(THEME_SPACING_MD, 1))
                            }

                            engine.ui_spacer(engine.ui_px(12, 1))

                            engine.ui_set_next_text_color(engine.color_hex_rgb(is_active ? THEME_TEXT_PRIMARY_DEFAULT[state.config.theme] : THEME_TEXT_SECONDARY_DEFAULT[state.config.theme]))
                            engine.ui_set_next_font_size(14)
                            engine.ui_text(name)

                            if is_active && !engine.ui_hovering(item_sig) {
                                engine.ui_spacer(engine.ui_fill())
                                engine.ui_set_next_text_color(engine.color_hex_rgb(THEME_TEXT_BRAND_DEFAULT[state.config.theme]))
                                engine.ui_text_sized(ICONS[.Check], 16)
                            }

                            if engine.ui_hovering(item_sig) {
                                engine.ui_spacer(engine.ui_fill())
                                engine.ui_set_next_text_color(engine.color_hex_rgb(THEME_TEXT_SECONDARY_DEFAULT[state.config.theme]))
                                engine.ui_text_sized(ICONS[.ThreeDots], 12)
                                // TODO: clicking the threedots should open the menu to do stuff
                            }
                        }

                        if engine.ui_clicked(engine.ui_signal_from_box(item_box)) && !is_active {
                            state.active_workspace_index = i
                            engine.ui_popup_close()
                            save_workspaces()
                        }
                    }
                }

                engine.ui_spacer(engine.ui_px(6, 1))

                if draw_button("Create Workspace", variant = .LinkColored, size = .Small, left_icon = .Plus) {
                    // TODO: open workspace creation dialog
                }

                engine.ui_popup_end()
            }


            engine.ui_pop_pref_height()
        }

        engine.ui_spacer(engine.ui_percent(1, 0.05))
        if draw_icon_button(.Settings, engine.color_hex_rgb(THEME_ICON_SECONDARY_DEFAULT[state.config.theme]), size = .ExtraSmall, variant = .SecondaryGrey, tooltip_text = "Settings") {
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
            engine.color_hex_rgb(THEME_BACKGROUND_BRAND_SOLID_HOVER[state.config.theme]),
            engine.color_hex_rgb(THEME_BACKGROUND_PRIMARY_DISABLED[state.config.theme]),
            TRANSPARENT,
            engine.color_hex_rgb(THEME_BORDER_PRIMARY_DEFAULT[state.config.theme]),
            engine.color_hex_rgb(THEME_TEXT_SECONDARY_INVERSE[state.config.theme]),
            engine.color_hex_rgb(THEME_TEXT_SECONDARY_INVERSE[state.config.theme]),
            engine.color_hex_rgb(THEME_TEXT_PRIMARY_DISABLED[state.config.theme]),
        },
        .SecondaryGrey = {
            engine.color_hex_rgb(THEME_BACKGROUND_PRIMARY_DEFAULT[state.config.theme]),
            engine.color_hex_rgb(THEME_BACKGROUND_SECONDARY_DEFAULT[state.config.theme]),
            engine.color_hex_rgb(THEME_BACKGROUND_PRIMARY_DISABLED[state.config.theme]),
            engine.color_hex_rgb(THEME_BORDER_PRIMARY_DEFAULT[state.config.theme]),
            engine.color_hex_rgb(THEME_BORDER_PRIMARY_DEFAULT[state.config.theme]),
            engine.color_hex_rgb(THEME_TEXT_SECONDARY_DEFAULT[state.config.theme]),
            engine.color_hex_rgb(THEME_TEXT_SECONDARY_HOVER[state.config.theme]),
            engine.color_hex_rgb(THEME_TEXT_PRIMARY_DISABLED[state.config.theme]),
        },
        .SecondaryColored = {
            engine.color_hex_rgb(THEME_BACKGROUND_PRIMARY_DEFAULT[state.config.theme]),
            engine.color_hex_rgb(THEME_BACKGROUND_BRAND_DEFAULT_HOVER[state.config.theme]),
            engine.color_hex_rgb(THEME_BACKGROUND_PRIMARY_DISABLED[state.config.theme]),
            engine.color_hex_rgb(THEME_BORDER_BRAND_DEFAULT),
            engine.color_hex_rgb(THEME_BORDER_PRIMARY_DEFAULT[state.config.theme]),
            engine.color_hex_rgb(THEME_TEXT_BRAND_DEFAULT[state.config.theme]),
            engine.color_hex_rgb(THEME_TEXT_BRAND_DEFAULT[state.config.theme]),
            engine.color_hex_rgb(THEME_TEXT_PRIMARY_DISABLED[state.config.theme]),
        },
        .TertiaryGrey = {
            TRANSPARENT,
            engine.color_hex_rgb(THEME_BACKGROUND_SECONDARY_DEFAULT[state.config.theme]),
            TRANSPARENT,
            TRANSPARENT,
            TRANSPARENT,
            engine.color_hex_rgb(THEME_TEXT_TERTIARY_DEFAULT[state.config.theme]),
            engine.color_hex_rgb(THEME_TEXT_SECONDARY_DEFAULT[state.config.theme]),
            engine.color_hex_rgb(THEME_TEXT_PRIMARY_DISABLED[state.config.theme]),
        },
        .TertiaryColored = {
            TRANSPARENT,
            engine.color_hex_rgb(THEME_BACKGROUND_PRIMARY_DEFAULT_HOVER[state.config.theme]),
            TRANSPARENT,
            TRANSPARENT,
            TRANSPARENT,
            engine.color_hex_rgb(THEME_TEXT_BRAND_DEFAULT[state.config.theme]),
            engine.color_hex_rgb(THEME_TEXT_BRAND_DEFAULT[state.config.theme]),
            engine.color_hex_rgb(THEME_TEXT_PRIMARY_DISABLED[state.config.theme]),
        },
        .LinkGrey = {
            TRANSPARENT,
            TRANSPARENT,
            TRANSPARENT,
            TRANSPARENT,
            TRANSPARENT,
            engine.color_hex_rgb(THEME_TEXT_SECONDARY_DEFAULT[state.config.theme]),
            engine.color_hex_rgb(THEME_TEXT_SECONDARY_HOVER[state.config.theme]),
            engine.color_hex_rgb(THEME_TEXT_PRIMARY_DISABLED[state.config.theme]),
        },
        .LinkColored = {
            TRANSPARENT,
            TRANSPARENT,
            TRANSPARENT,
            TRANSPARENT,
            TRANSPARENT,
            engine.color_hex_rgb(THEME_TEXT_BRAND_DEFAULT[state.config.theme]),
            engine.color_hex_rgb(THEME_TEXT_BRAND_HOVER[state.config.theme]),
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

    clicked, box := engine.ui_button_styled_with_icons(label, style, left_icon = left_icon_text, right_icon = right_icon_text, enabled = enabled)
    if engine.ui_hovering(engine.ui_signal_from_box(box)) {
        engine.set_cursor(.HAND)
    }
    return clicked
}

@require_results
draw_icon_button :: proc(
    icon: ICON,
    icon_color: Maybe(engine.Color) = nil,
    icon_size: i32 = 20,
    variant := ButtonVariant.Primary,
    size := IconButtonSize.Medium,
    enabled := true,
    tooltip_text: string,
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
            engine.color_hex_rgb(THEME_BACKGROUND_BRAND_SOLID_HOVER[state.config.theme]),
            engine.color_hex_rgb(THEME_BACKGROUND_PRIMARY_DISABLED[state.config.theme]),
            TRANSPARENT,
            engine.color_hex_rgb(THEME_BORDER_PRIMARY_DEFAULT[state.config.theme]),
            engine.color_hex_rgb(THEME_TEXT_SECONDARY_INVERSE[state.config.theme]),
            engine.color_hex_rgb(THEME_TEXT_SECONDARY_INVERSE[state.config.theme]),
            engine.color_hex_rgb(THEME_TEXT_PRIMARY_DISABLED[state.config.theme]),
        },
        .SecondaryGrey = {
            engine.color_hex_rgb(THEME_BACKGROUND_PRIMARY_DEFAULT[state.config.theme]),
            engine.color_hex_rgb(THEME_BACKGROUND_SECONDARY_DEFAULT[state.config.theme]),
            engine.color_hex_rgb(THEME_BACKGROUND_PRIMARY_DISABLED[state.config.theme]),
            engine.color_hex_rgb(THEME_BORDER_PRIMARY_DEFAULT[state.config.theme]),
            engine.color_hex_rgb(THEME_BORDER_PRIMARY_DEFAULT[state.config.theme]),
            engine.color_hex_rgb(THEME_TEXT_SECONDARY_DEFAULT[state.config.theme]),
            engine.color_hex_rgb(THEME_TEXT_SECONDARY_HOVER[state.config.theme]),
            engine.color_hex_rgb(THEME_TEXT_PRIMARY_DISABLED[state.config.theme]),
        },
        .SecondaryColored = {
            engine.color_hex_rgb(THEME_BACKGROUND_PRIMARY_DEFAULT[state.config.theme]),
            engine.color_hex_rgb(THEME_BACKGROUND_BRAND_DEFAULT_HOVER[state.config.theme]),
            engine.color_hex_rgb(THEME_BACKGROUND_PRIMARY_DISABLED[state.config.theme]),
            engine.color_hex_rgb(THEME_BORDER_BRAND_DEFAULT),
            engine.color_hex_rgb(THEME_BORDER_PRIMARY_DEFAULT[state.config.theme]),
            engine.color_hex_rgb(THEME_TEXT_BRAND_DEFAULT[state.config.theme]),
            engine.color_hex_rgb(THEME_TEXT_BRAND_DEFAULT[state.config.theme]),
            engine.color_hex_rgb(THEME_TEXT_PRIMARY_DISABLED[state.config.theme]),
        },
        .TertiaryGrey = {
            TRANSPARENT,
            engine.color_hex_rgb(THEME_BACKGROUND_SECONDARY_DEFAULT[state.config.theme]),
            TRANSPARENT,
            TRANSPARENT,
            TRANSPARENT,
            engine.color_hex_rgb(THEME_TEXT_TERTIARY_DEFAULT[state.config.theme]),
            engine.color_hex_rgb(THEME_TEXT_SECONDARY_DEFAULT[state.config.theme]),
            engine.color_hex_rgb(THEME_TEXT_PRIMARY_DISABLED[state.config.theme]),
        },
        .TertiaryColored = {
            TRANSPARENT,
            engine.color_hex_rgb(THEME_BACKGROUND_PRIMARY_DEFAULT_HOVER[state.config.theme]),
            TRANSPARENT,
            TRANSPARENT,
            TRANSPARENT,
            engine.color_hex_rgb(THEME_TEXT_BRAND_DEFAULT[state.config.theme]),
            engine.color_hex_rgb(THEME_TEXT_BRAND_DEFAULT[state.config.theme]),
            engine.color_hex_rgb(THEME_TEXT_PRIMARY_DISABLED[state.config.theme]),
        },
        .LinkGrey = {
            TRANSPARENT,
            TRANSPARENT,
            TRANSPARENT,
            TRANSPARENT,
            TRANSPARENT,
            engine.color_hex_rgb(THEME_TEXT_SECONDARY_DEFAULT[state.config.theme]),
            engine.color_hex_rgb(THEME_TEXT_SECONDARY_HOVER[state.config.theme]),
            engine.color_hex_rgb(THEME_TEXT_PRIMARY_DISABLED[state.config.theme]),
        },
        .LinkColored = {
            TRANSPARENT,
            TRANSPARENT,
            TRANSPARENT,
            TRANSPARENT,
            TRANSPARENT,
            engine.color_hex_rgb(THEME_TEXT_BRAND_DEFAULT[state.config.theme]),
            engine.color_hex_rgb(THEME_TEXT_BRAND_HOVER[state.config.theme]),
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
    clicked, box := engine.ui_button_styled(ICONS[icon], style, enabled = enabled)
    if engine.ui_hovering(engine.ui_signal_from_box(box)) {
        engine.set_cursor(.HAND)

        engine.ui_set_next_font_size(THEME_FONT_SIZE_LABEL)
        engine.ui_set_next_background_color(engine.color_hex_rgb(THEME_BACKGROUND_SECONDARY_DEFAULT[state.config.theme]))
        engine.ui_set_next_border_thickness(0.5)
        engine.ui_set_next_border_color(engine.color_hex_rgb(THEME_BORDER_PRIMARY_DEFAULT[state.config.theme]))
        engine.ui_tooltip_text(tooltip_text, target = box)
    }

    return clicked
}

draw_collections_list :: proc() {
    engine.ui_set_next_width(engine.ui_fill())
    engine.ui_set_next_height(engine.ui_fill())
    engine.ui_column(); {
        engine.ui_padding(12, {.Left})

        {
            engine.ui_set_next_align_x(.End)
            engine.ui_set_next_align_y(.Center)
            engine.ui_set_next_width(engine.ui_fill())
            engine.ui_set_next_height(engine.ui_children_sum(1))
            engine.ui_row(); {
                engine.ui_padding(12, {.Right})
                if draw_button("New", .LinkColored, .Small, left_icon = .Plus) {
                    // TODO: new collection dialog
                }
                engine.ui_spacer(engine.ui_px(12, 1))
                if draw_button("Import", .LinkColored, .Small) {
                    // TODO: import
                }
            }
        }

        engine.ui_spacer(engine.ui_px(12, 1))

        if len(state.workspaces[state.active_workspace_index].collections) == 0 {
            // TODO: draw empty state
        }

        engine.ui_set_next_width(engine.ui_fill())
        engine.ui_set_next_height(engine.ui_fill())
        engine.ui_row(); {
            scroll_box: ^engine.Box
            {
                // TODO: only draw the border when drag is accepted
                extra_flags := engine.Flags{/*.DrawBorder*/}

                engine.ui_set_next_border_color(engine.color_hex_rgb(THEME_BORDER_BRAND_DEFAULT))
                engine.ui_set_next_border_thickness(1.5)
                engine.ui_set_next_border_radius(THEME_BORDER_RADIUS_MD)
                engine.ui_set_next_width(engine.ui_fill())
                engine.ui_set_next_height(engine.ui_fill())
                scroll_box = engine.ui_scroll_column(extra_flags = extra_flags); {
                    for collection in state.workspaces[state.active_workspace_index].collections {
                        draw_collection_item(collection)
                    }
                }
            }

            engine.ui_spacer(engine.ui_px(4, 1))
            SCROLLBAR_V(scroll_box)
            engine.ui_spacer(engine.ui_px(2, 1))
        }
    }
}

draw_collection_item :: proc(collection: ^Collection, indent_level := 0) {
    name := string(cstring(&collection.name[0]))

    {
        engine.ui_set_next_align_x(.Start)
        engine.ui_set_next_align_y(.Center)
        engine.ui_set_next_flags({.DrawBackground, .MouseClickable})
        engine.ui_set_next_border_radius(THEME_BORDER_RADIUS_MD)
        engine.ui_set_next_width(engine.ui_fill())
        engine.ui_set_next_height(engine.ui_children_sum(1))

        id := engine.ui_make_id(fmt.tprintf("collection_%d", collection.id))

        box := engine.ui_row(id); sig := engine.ui_signal_from_box(box); {
            if engine.ui_hovering(sig) {
                engine.set_cursor(.HAND)
                box.background_color = engine.color_hex_rgb(THEME_BACKGROUND_SECONDARY_DEFAULT_HOVER[state.config.theme])
            } else {
                box.background_color = TRANSPARENT
            }

            engine.ui_padding(6, {.Left})
            engine.ui_padding(12, {.Right})
            engine.ui_padding(4, {.Top, .Bottom})

            if engine.ui_hovering(sig) {
                engine.ui_push_text_color(engine.color_hex_rgb(THEME_TEXT_SECONDARY_HOVER[state.config.theme]))
            } else {
                engine.ui_push_text_color(engine.color_hex_rgb(THEME_TEXT_SECONDARY_DEFAULT[state.config.theme]))
            }

            engine.ui_spacer(engine.ui_px(f32(20 * indent_level), 1))

            {
                engine.ui_set_next_width(engine.ui_fill())
                engine.ui_set_next_height(engine.ui_children_sum(1))
                engine.ui_set_next_align_y(.Center)
                engine.ui_row(); {
                    // Chevron points down when expanded, right when collapsed
                    engine.ui_set_next_rotation(collection.is_expanded ? 0 : math.to_radians_f32(-90))
                    engine.ui_text_sized(ICONS[.Chevron], 12)

                    engine.ui_spacer(engine.ui_px(4, 1))

                    engine.ui_set_next_font_size(14)
                    engine.ui_text_shrinkable(name)
                    engine.ui_pop_text_color()
                }
            }

            if engine.ui_hovering(sig) {
                engine.ui_spacer(engine.ui_px(8, 1))
                engine.ui_set_next_text_color(engine.color_hex_rgb(THEME_TEXT_SECONDARY_DEFAULT[state.config.theme]))
                // TODO: should return signal or box so we can use it for hover and click
                engine.ui_text_sized(ICONS[.LinkExternal], 16)

                engine.ui_spacer(engine.ui_px(10, 1))

                {
                    engine.ui_set_next_width(engine.ui_children_sum(1))
                    engine.ui_set_next_height(engine.ui_children_sum(1))
                    engine.ui_set_next_flags({.MouseClickable})

                    id := engine.ui_make_id(fmt.tprintf("collection_%d_plus", collection.id))

                    plus := engine.ui_row(id); {
                        plus_sig := engine.ui_signal_from_box(plus)
                        engine.ui_set_next_text_color(engine.color_hex_rgb(engine.ui_hovering(plus_sig) ? THEME_TEXT_PRIMARY_DEFAULT[state.config.theme] : THEME_TEXT_SECONDARY_DEFAULT[state.config.theme]))
                        engine.ui_text_sized(ICONS[.Plus], 12)

                        if engine.ui_clicked(plus_sig) {
                            new_request_tab()

                            request := state.tabs[len(state.tabs) - 1].(^Request)
                            request.collection = collection

                            collection_request := Request{}
                            collection_request.id = request.id
                            collection_request.method = request.method
                            collection_request.modification_hash = request.modification_hash
                            collection_request.collection = collection
                            copy(collection_request.name[:], request.name[:])

                            collection_request.query_params = make([dynamic]QueryParam, len(request.query_params))

                            collection_request.headers = make([dynamic]RequestHeader, len(request.headers))
                            copy(collection_request.headers[:], request.headers[:])

                            collection_request.path_params = make(map[string]PathParam)
                            for key, &value in request.path_params {
                                new_value := PathParam{}
                                copy(new_value.value[:], value.value[:])
                                new_value.indices = make([dynamic]PathParamIndex, len(value.indices))
                                copy(new_value.indices[:], value.indices[:])
                                collection_request.path_params[strings.clone(key)] = new_value
                            }

                            append(&collection.requests, collection_request)
                            state.active_tab_index = len(state.tabs) - 1
                            collection.is_expanded = true

                            save_workspaces()
                        }
                    }
                }

                engine.ui_spacer(engine.ui_px(10, 1))

                engine.ui_set_next_text_color(engine.color_hex_rgb(THEME_TEXT_SECONDARY_DEFAULT[state.config.theme]))
                // TODO: should return signal or box so we can use it for hover and click
                engine.ui_text_sized(ICONS[.ThreeDots], 12)
            }
        }

        if engine.ui_clicked(sig) {
            collection.is_expanded = !collection.is_expanded
        }
    }

    if collection.is_expanded {
        if collection.first == nil && len(collection.requests) == 0 {
            engine.ui_set_next_height(engine.ui_px(60, 1))
            engine.ui_set_next_width(engine.ui_fill())
            engine.ui_row(); {
                engine.ui_spacer(engine.ui_px(f32(indent_level) * 20 + 11, 1))
                BORDER_V()
                engine.ui_set_next_height(engine.ui_fill())
                engine.ui_set_next_width(engine.ui_fill())
                engine.ui_set_next_align_y(.Center)
                engine.ui_set_next_align_x(.Center)
                engine.ui_row(); {
                    engine.ui_set_next_text_color(engine.color_hex_rgb(THEME_TEXT_SECONDARY_DEFAULT[state.config.theme]))
                    engine.ui_text("Collection is empty")
                }
            }
        } else {
            for child := collection.first; child != nil; child = child.next {
                draw_collection_item(child, indent_level + 1)
            }
            for &request in collection.requests {
                draw_request_item(&request, indent_level + 1)
            }
        }
    }
}

draw_request_item :: proc(request: ^Request, indent_level := 0) {
    name := string(cstring(&request.name[0]))
    method := http_method_string(request.method)

    engine.ui_set_next_align_x(.Start)
    engine.ui_set_next_align_y(.Center)
    engine.ui_set_next_flags({.DrawBackground, .MouseClickable})
    engine.ui_set_next_border_radius(THEME_BORDER_RADIUS_MD)
    engine.ui_set_next_width(engine.ui_fill())
    engine.ui_set_next_height(engine.ui_children_sum(1))

    id := engine.ui_make_id(fmt.tprintf("request_%d", request.id))

    box := engine.ui_row(id); sig := engine.ui_signal_from_box(box); {
        if engine.ui_hovering(sig) {
            engine.set_cursor(.HAND)
            box.background_color = engine.color_hex_rgb(THEME_BACKGROUND_SECONDARY_DEFAULT_HOVER[state.config.theme])
        } else {
            box.background_color = TRANSPARENT
        }

        engine.ui_padding(6, {.Left})
        engine.ui_padding(12, {.Right})
        engine.ui_padding(4, {.Top, .Bottom})

        engine.ui_spacer(engine.ui_px(f32(20 * indent_level), 1))

        {
            engine.ui_set_next_width(engine.ui_fill())
            engine.ui_set_next_height(engine.ui_children_sum(1))
            engine.ui_set_next_align_y(.Center)
            engine.ui_row(); {

                {
                    engine.ui_set_next_width(engine.ui_px(28, 1))
                    engine.ui_set_next_max_width(28)
                    engine.ui_set_next_height(engine.ui_children_sum(1))
                    engine.ui_row(); {
                        engine.ui_spacer(engine.ui_fill())

                        engine.ui_set_next_font_weight(THEME_FONT_WEIGHT_HEADING)
                        engine.ui_set_next_font_size(10)
                        engine.ui_set_next_text_color(http_method_color(request.method))
                        engine.ui_set_next_width(engine.ui_px(28, 1))
                        engine.ui_set_next_max_width(28)
                        engine.ui_text(method)
                    }
                }

                engine.ui_spacer(engine.ui_px(6, 1))

                if engine.ui_hovering(sig) {
                    engine.ui_push_text_color(engine.color_hex_rgb(THEME_TEXT_SECONDARY_HOVER[state.config.theme]))
                } else {
                    engine.ui_push_text_color(engine.color_hex_rgb(THEME_TEXT_SECONDARY_DEFAULT[state.config.theme]))
                }
                engine.ui_set_next_font_size(14)
                engine.ui_text_shrinkable(name)
                engine.ui_pop_text_color()
            }
        }

        if engine.ui_hovering(sig) {
            engine.ui_spacer(engine.ui_px(8, 1))
            engine.ui_set_next_text_color(engine.color_hex_rgb(THEME_TEXT_SECONDARY_DEFAULT[state.config.theme]))
            // TODO: should return signal or box so we can use it for hover and click
            engine.ui_text_sized(ICONS[.ThreeDots], 12)
        }
    }

    if engine.ui_clicked(sig) {
        for tab, i in state.tabs {
            r, is_request := tab.(^Request)
            if !is_request { continue }
            if r.id == request.id {
                state.active_tab_index = i
                return
            }
        }

        new_request_tab()

        tab_req := state.tabs[len(state.tabs)-1].(^Request)

        copy_request_data(tab_req, request)
        tab_req.id = request.id

        // Ensure url and query params are canonicalized when opening from collections.
        // Some persisted requests may have query params stored separately while the url
        // does not include them yet.
        update_url_from_query_params(tab_req)
        parse_path_params_from_url(tab_req)
        tab_req.modification_hash = hash_request(tab_req)
        tab_req.is_modified = false
        state.active_tab_index = len(state.tabs)-1
    }
}

draw_environments_list :: proc() {
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
                    // TODO: new environments dialog
                }
                engine.ui_spacer(engine.ui_px(12, 1))
                if draw_button("Import", .LinkColored, .Small) {
                    // TODO: import
                }
            }
        }

        engine.ui_spacer(engine.ui_px(12, 1))

        if len(state.workspaces[state.active_workspace_index].environments) == 0 {
            // TODO: draw empty state
        }

        engine.ui_set_next_width(engine.ui_fill())
        engine.ui_set_next_height(engine.ui_fill())
        engine.ui_column(); {
            for &environment in state.workspaces[state.active_workspace_index].environments {
                draw_environment_item(&environment)
            }
        }
    }
}

draw_environment_item :: proc(environment: ^Environment) {
    name := string(cstring(&environment.name[0]))

    engine.ui_set_next_align_x(.Start)
    engine.ui_set_next_align_y(.Center)
    engine.ui_set_next_flags({.DrawBackground, .MouseClickable})
    engine.ui_set_next_border_radius(THEME_BORDER_RADIUS_MD)
    engine.ui_set_next_width(engine.ui_fill())
    engine.ui_set_next_height(engine.ui_children_sum(1))

    id := engine.ui_make_id(fmt.tprintf("environment_%d", environment.id))

    box := engine.ui_row(id); {
        sig := engine.ui_signal_from_box(box)
        if engine.ui_hovering(sig) {
            engine.set_cursor(.HAND)
            box.background_color = engine.color_hex_rgb(THEME_BACKGROUND_SECONDARY_DEFAULT_HOVER[state.config.theme])
        } else {
            box.background_color = TRANSPARENT
        }

        engine.ui_padding(6, {.Left})
        engine.ui_padding(12, {.Right})
        engine.ui_padding(4, {.Top, .Bottom})

        if engine.ui_hovering(sig) {
            engine.ui_push_text_color(engine.color_hex_rgb(THEME_TEXT_SECONDARY_HOVER[state.config.theme]))
        } else {
            engine.ui_push_text_color(engine.color_hex_rgb(THEME_TEXT_SECONDARY_DEFAULT[state.config.theme]))
        }

        engine.ui_spacer(engine.ui_px(4, 1))

        {
            engine.ui_set_next_width(engine.ui_fill())
            engine.ui_set_next_height(engine.ui_children_sum(1))
            engine.ui_set_next_align_y(.Center)
            engine.ui_row(); {
                engine.ui_set_next_font_size(14)
                engine.ui_text_shrinkable(name)
                engine.ui_pop_text_color()
            }
        }

        if engine.ui_hovering(sig) {
            engine.ui_spacer(engine.ui_px(8, 1))
            engine.ui_set_next_text_color(engine.color_hex_rgb(THEME_TEXT_SECONDARY_DEFAULT[state.config.theme]))
            // TODO: should return signal or box so we can use it for hover and click
            engine.ui_text_sized(ICONS[.ThreeDots], 12)
        }
    }
}

draw_sidebar :: proc() {
    engine.ui_set_next_width(engine.ui_px(state.config.sidebar_width, 1))
    engine.ui_set_next_height(engine.ui_fill())
    engine.ui_set_next_background_color(engine.color_hex_rgb(THEME_BACKGROUND_SECONDARY_DEFAULT[state.config.theme]))
    engine.ui_set_next_flags({.DrawBackground})
    engine.ui_row(); {
        engine.ui_padding(12, {.Top, .Bottom})
        {
            engine.ui_set_next_height(engine.ui_fill())
            engine.ui_set_next_width(engine.ui_children_sum(1))
            engine.ui_column(); { // Vertical Tabs
                engine.ui_padding(16, {.Left})
                engine.ui_padding(12, {.Right})

                if draw_icon_button(.Folder, engine.color_hex_rgb(state.config.sidebar_tab == .Collections ? THEME_BACKGROUND_PRIMARY_DEFAULT[state.config.theme] : THEME_ICON_SECONDARY_DEFAULT[state.config.theme]), size = .Small, variant = state.config.sidebar_tab == .Collections ? .Primary : .SecondaryGrey, tooltip_text = "Collections") {
                    state.config.sidebar_tab = .Collections
                    save_config()
                }
                engine.ui_spacer(engine.ui_px(10, 1))
                if draw_icon_button(.Environment, engine.color_hex_rgb(state.config.sidebar_tab == .Environments ? THEME_BACKGROUND_PRIMARY_DEFAULT[state.config.theme] : THEME_ICON_SECONDARY_DEFAULT[state.config.theme]), size = .Small, variant = state.config.sidebar_tab == .Environments ? .Primary : .SecondaryGrey, tooltip_text = "Environments") {
                    state.config.sidebar_tab = .Environments
                    save_config()
                }
            }
        }
        BORDER_V()
        switch state.config.sidebar_tab { // Content Area
        case .Collections:
            draw_collections_list()
        case .Environments:
            draw_environments_list()
        }
    }
}

draw_tab_item_request :: proc(req: ^Request, index: int) {
    engine.ui_set_next_width(engine.ui_children_sum(1))
    engine.ui_set_next_height(engine.ui_fill())
    engine.ui_set_next_align_y(.Center)
    engine.ui_set_next_flags({.DrawBackground})
    tab_box := engine.ui_column(); {
        if state.active_tab_index == index {
            tab_box.background_color = engine.color_hex_rgb(THEME_BACKGROUND_SECONDARY_DEFAULT[state.config.theme])
        } else {
            tab_box.background_color = TRANSPARENT
        }

        tab_hovered: bool
        {
            engine.ui_set_next_width(engine.ui_children_sum(1))
            engine.ui_set_next_height(engine.ui_fill())
            engine.ui_set_next_align_y(.Center)
            engine.ui_set_next_flags({.MouseClickable})

            id := engine.ui_make_id(fmt.tprintf("request_tab_%d", req.id))

            tab_box := engine.ui_row(id); {
                tab_sig := engine.ui_signal_from_box(tab_box)
                tab_hovered = engine.ui_hovering(tab_sig)

                if engine.ui_clicked(tab_sig) {
                    state.active_tab_index = index
                }

                engine.ui_padding(12, {.Left, .Right})

                name := string(cstring(&req.name[0]))
                name_raw_w := engine.ui_text_measure_string(name, THEME_FONT_SIZE_BODY_SM).x

                {
                    engine.ui_set_next_height(engine.ui_children_sum(1))
                    engine.ui_set_next_width(engine.ui_children_sum(1))
                    engine.ui_set_next_align_y(.Center)
                    engine.ui_row(); {
                        engine.ui_set_next_font_size(10)
                        engine.ui_set_next_font_weight(900)
                        engine.ui_set_next_text_color(http_method_color(req.method))
                        engine.ui_text(http_method_string(req.method))

                        engine.ui_spacer(engine.ui_px(THEME_SPACING_MD, 1))

                        if name_raw_w < 80 {
                            engine.ui_push_pref_width(engine.ui_text_dim(0, 1))
                        } else {
                            engine.ui_push_pref_width(engine.ui_px(80, 1))
                        }
                        engine.ui_set_next_font_size(THEME_FONT_SIZE_BODY_SM)
                        engine.ui_set_next_text_color(engine.color_hex_rgb(tab_hovered || state.active_tab_index == index ? THEME_TEXT_PRIMARY_DEFAULT[state.config.theme] : THEME_TEXT_SECONDARY_DEFAULT[state.config.theme]))
                        engine.ui_text(name)
                        engine.ui_pop_pref_width()

                        if tab_hovered && name_raw_w >= 80 {
                            engine.ui_set_next_font_size(THEME_FONT_SIZE_LABEL)
                            engine.ui_set_next_background_color(engine.color_hex_rgb(THEME_BACKGROUND_SECONDARY_DEFAULT[state.config.theme]))
                            engine.ui_set_next_border_thickness(0.5)
                            engine.ui_set_next_border_color(engine.color_hex_rgb(THEME_BORDER_PRIMARY_DEFAULT[state.config.theme]))
                            engine.ui_tooltip_text(name)
                        }
                    }
                }


                if tab_hovered {
                    engine.ui_spacer(engine.ui_px(THEME_SPACING_SM, 1))
                } else {
                    engine.ui_spacer(engine.ui_px(THEME_SPACING_MD, 1))
                }

                if tab_hovered {
                    engine.ui_set_next_width(engine.ui_children_sum(1))
                    engine.ui_set_next_height(engine.ui_children_sum(1))
                    engine.ui_set_next_align_y(.Center)
                    engine.ui_set_next_align_x(.Center)
                    engine.ui_set_next_flags({.MouseClickable, .DrawBackground})
                    engine.ui_set_next_border_radius(THEME_BORDER_RADIUS_MD)
                    engine.ui_set_next_background_color(TRANSPARENT)

                    id := engine.ui_make_id(fmt.tprintf("close_request_tab_%d", req.id))

                    box := engine.ui_row(id); {
                        sig := engine.ui_signal_from_box(box)

                        engine.ui_padding(4, {.Left, .Right, .Top, .Bottom})

                        engine.ui_set_next_text_color(engine.color_hex_rgb(THEME_TEXT_SECONDARY_DEFAULT[state.config.theme]))
                        text_box := engine.ui_text(ICONS[.Close])
                        if engine.ui_hovering(sig) {
                            text_box.text_color = engine.color_hex_rgb(THEME_TEXT_PRIMARY_DEFAULT[state.config.theme])
                            box.background_color = engine.color_hex_rgb(state.active_tab_index == index ? THEME_BACKGROUND_PRIMARY_DEFAULT_ALT[state.config.theme] : THEME_BACKGROUND_PRIMARY_DEFAULT_HOVER[state.config.theme])

                            engine.ui_set_next_font_size(THEME_FONT_SIZE_LABEL)
                            engine.ui_set_next_background_color(engine.color_hex_rgb(THEME_BACKGROUND_SECONDARY_DEFAULT[state.config.theme]))
                            engine.ui_set_next_border_thickness(0.5)
                            engine.ui_set_next_border_color(engine.color_hex_rgb(THEME_BORDER_PRIMARY_DEFAULT[state.config.theme]))
                            engine.ui_tooltip_text("Close Tab", target = box)
                        }

                        if engine.ui_clicked(sig) {
                            log.debug("TODO: close tab at index", index)
                        }
                    }
                } else {
                    engine.ui_spacer(engine.ui_px(16, 1))
                }
            }
        }

        {
            method_str := http_method_string(req.method)
            method_w := engine.ui_text_measure_string(method_str, 10, 900).x
            name := string(cstring(&req.name[0]))
            name_raw_w := engine.ui_text_measure_string(name, THEME_FONT_SIZE_BODY_SM).x
            name_w := min(name_raw_w, f32(80))
            close_icon_w := engine.ui_text_measure_string(ICONS[.Close], 14).x

            item_w := f32(12)
            item_w += method_w + f32(THEME_SPACING_MD) + name_w
            if tab_hovered {
                item_w += f32(THEME_SPACING_SM)
                item_w += 4 + close_icon_w + 4 + 3
            } else {
                item_w += f32(THEME_SPACING_MD)
                item_w += 16 + 1
            }
            item_w += 12

            engine.ui_set_next_width(engine.ui_px(item_w, 1))
            engine.ui_set_next_height(engine.ui_px(1, 1))
            engine.ui_set_next_background_color(state.active_tab_index == index ? engine.color_hex_rgb(THEME_BORDER_BRAND_DEFAULT) : TRANSPARENT)
            engine.ui_set_next_flags({.DrawBackground})
            engine.ui_row()
        }
    }
}

draw_tab_bar :: proc() {
    window_size := engine.get_window_size()
    sidebar_width := state.config.sidebar_width
    border_width := f32(1)
    tab_bar_width := window_size.x - sidebar_width - border_width

    env_text_sz := engine.ui_text_measure_string("No Environment", 16)
    env_icon_sz := engine.ui_text_measure_string(ICONS[.Environment], 16)
    chevron_sz := engine.ui_text_measure_string(ICONS[.Chevron], 16)
    env_button_w := env_text_sz.x + env_icon_sz.x + chevron_sz.x + 16*2 + 8 + 8

    env_section_w := 4 + 1 + env_button_w

    plus_sz := engine.ui_text_measure_string(ICONS[.Plus], 16)
    plus_button_w := plus_sz.x + 10*2

    available_width := max(tab_bar_width - plus_button_w - env_section_w - 4 - 2, 0)

    engine.ui_set_next_width(engine.ui_fill())
    engine.ui_set_next_height(engine.ui_px(40, 1))
    engine.ui_set_next_align_y(.Center)
    engine.ui_row(); {
        {
            engine.ui_set_next_width(engine.ui_children_sum(1))
            engine.ui_set_next_height(engine.ui_children_sum(1))
            engine.ui_set_next_max_width(available_width)
            engine.ui_scroll_row(); {
                for tab, index in state.tabs {
                    switch t in tab {
                    case ^Request:
                        draw_tab_item_request(t, index)
                    case ^Environment:
                        // TODO:
                    case ^Collection:
                        // TODO:
                    }
                }
            }
        }

        engine.ui_spacer(engine.ui_px(4, 1))
        if draw_icon_button(.Plus, engine.color_hex_rgb(THEME_ICON_SECONDARY_DEFAULT[state.config.theme]), 16, .TertiaryGrey, .Small, tooltip_text = "New Request Tab") {
            new_request_tab()
            state.active_tab_index = len(state.tabs) - 1
        }

        engine.ui_spacer(engine.ui_fill())

        {
            engine.ui_set_next_width(engine.ui_children_sum(1))
            engine.ui_set_next_height(engine.ui_children_sum(1))
            engine.ui_row(); {
                engine.ui_spacer(engine.ui_px(4, 1))
                BORDER_V()
                if draw_button("No Environment", .TertiaryGrey, left_icon = .Environment, right_icon = .Chevron) {
                    // TODO: open environment popup
                }
            }
        }
    }
}

draw_main_area :: proc() {
    engine.ui_set_next_width(engine.ui_fill())
    engine.ui_set_next_height(engine.ui_fill())
    engine.ui_column(); {
        draw_tab_bar()

        BORDER_H()

        // Empty state
        if state.active_tab_index == -1 {
            engine.ui_set_next_align_x(.Center)
            engine.ui_set_next_align_y(.Center)
            engine.ui_set_next_width(engine.ui_fill())
            engine.ui_set_next_height(engine.ui_fill())
            engine.ui_column(); {
                engine.ui_set_next_text_color(engine.color_hex_rgb(THEME_BACKGROUND_BRAND_DEFAULT[state.config.theme]))
                engine.ui_set_next_fixed_height(0)
                engine.ui_text_sized(ICONS[.EmptyState], 200)

                engine.ui_set_next_text_color(engine.color_hex_rgb(THEME_TEXT_PRIMARY_DEFAULT[state.config.theme]))
                engine.ui_text_sized("Open a new request tab using Ctrl+T or by pressing the + button", THEME_FONT_SIZE_BODY_SM)
            }
        } else {
            switch tab in state.tabs[state.active_tab_index] {
            case ^Request:
                draw_request_main_area(tab)
            case ^Collection:
                // draw_collection_main_area(tab)
            case ^Environment:
                // draw_environment_main_area(tab)
            }
        }
    }
}

draw_checkbox :: proc(checked: ^bool, label: string) {
    engine.ui_set_next_width(engine.ui_children_sum(1))
    engine.ui_set_next_height(engine.ui_children_sum(1))
    engine.ui_set_next_align_y(.Center)
    engine.ui_set_next_flags({.MouseClickable})
    box := engine.ui_row(); {
        sig := engine.ui_signal_from_box(box)

        if engine.ui_hovering(sig) {
            engine.set_cursor(.HAND)
        }

        {
            {
                if checked^ {
                    engine.ui_set_next_background_color(engine.color_hex_rgb(THEME_BACKGROUND_BRAND_DEFAULT[state.config.theme]))
                } else {
                    engine.ui_set_next_background_color(engine.color_hex_rgb(THEME_BACKGROUND_PRIMARY_DEFAULT_ALT[state.config.theme]))
                }
                engine.ui_set_next_width(engine.ui_px(20, 1))
                engine.ui_set_next_height(engine.ui_px(20, 1))
                engine.ui_set_next_border_thickness(0.5)
                if checked^ {
                    engine.ui_set_next_border_color(engine.color_hex_rgb(THEME_BORDER_BRAND_DEFAULT))
                } else {
                    engine.ui_set_next_border_color(engine.color_hex_rgb(THEME_BORDER_PRIMARY_DEFAULT[state.config.theme]))
                }
                engine.ui_set_next_border_radius(THEME_BORDER_RADIUS_SM)
                engine.ui_set_next_align_x(.Center)
                engine.ui_set_next_align_y(.Center)
                engine.ui_set_next_flags({.DrawBackground, .DrawBorder})
                engine.ui_row(); {
                    if checked^ {
                        engine.ui_set_next_text_color(engine.color_hex_rgb(THEME_ICON_BRAND_DEFAULT[state.config.theme]))
                        engine.ui_text(ICONS[.Check])
                    }
                }
            }
            engine.ui_spacer(engine.ui_px(10, 1))
            engine.ui_set_next_text_color(engine.color_hex_rgb(THEME_TEXT_SECONDARY_DEFAULT[state.config.theme]))
            engine.ui_text_sized(label, THEME_FONT_SIZE_BODY_SM)
        }

        if engine.ui_clicked(sig) {
            checked^ = !checked^
        }
    }
}

@require_results
// label is used to generate a unique id for the radio button.
draw_radio_button :: proc(label: string, selected: bool) -> bool {
    SIZE :: 16

    display_str := engine.ui_display_part_from_key_string(label)
    id_seed := hash.fnv32a(transmute([]byte)engine.ui_hash_part_from_key_string(label))

    engine.ui_set_next_width(engine.ui_children_sum(1))
    engine.ui_set_next_height(engine.ui_children_sum(1))
    engine.ui_set_next_align_y(.Center)
    engine.ui_set_next_flags({.MouseClickable})
    box := engine.ui_row(id_seed); {
        {
            {
                if selected {
                    engine.ui_set_next_background_color(engine.color_hex_rgb(THEME_BORDER_BRAND_DEFAULT))
                } else {
                    engine.ui_set_next_background_color(engine.color_hex_rgb(THEME_BACKGROUND_PRIMARY_DEFAULT_ALT[state.config.theme]))
                }
                engine.ui_set_next_width(engine.ui_px(SIZE, 1))
                engine.ui_set_next_height(engine.ui_px(SIZE, 1))
                engine.ui_set_next_border_thickness(selected ? 4 : 0.5)
                if selected {
                    engine.ui_set_next_border_color(engine.color_hex_rgb(THEME_BACKGROUND_BRAND_DEFAULT[state.config.theme]))
                } else {
                    engine.ui_set_next_border_color(engine.color_hex_rgb(THEME_BORDER_PRIMARY_DEFAULT[state.config.theme]))
                }
                engine.ui_set_next_border_radius(100)
                engine.ui_set_next_align_x(.Center)
                engine.ui_set_next_align_y(.Center)
                engine.ui_set_next_flags({.DrawBackground, .DrawBorder})
                engine.ui_row(); {
                    if selected {
                        engine.ui_set_next_background_color(engine.color_hex_rgb(THEME_ICON_BRAND_DEFAULT[state.config.theme]))
                        engine.ui_set_next_border_color(engine.color_hex_rgb(THEME_ICON_BRAND_DEFAULT[state.config.theme]))
                        engine.ui_set_next_width(engine.ui_px(10, 1))
                        engine.ui_set_next_height(engine.ui_px(10, 1))
                        engine.ui_set_next_border_radius(100)
                        engine.ui_row(); {
                            // inner circle
                        }
                    }
                }
            }
            engine.ui_spacer(engine.ui_px(6, 1))
            engine.ui_set_next_text_color(engine.color_hex_rgb(THEME_TEXT_SECONDARY_DEFAULT[state.config.theme]))
            engine.ui_text_sized(display_str, THEME_FONT_SIZE_BODY_SM)
        }
    }

    sig := engine.ui_signal_from_box(box)
    return engine.ui_clicked(sig)
}

draw_url_text_input :: proc(req: ^Request) {
    HEIGHT :: 44

    engine.ui_set_next_height(engine.ui_px(HEIGHT, 1))
    engine.ui_set_next_align_y(.Center)
    engine.ui_set_next_flags({.MouseClickable, .DrawBorder, .DrawBackground})
    engine.ui_set_next_border_thickness(0.5)
    engine.ui_set_next_border_radius(THEME_BORDER_RADIUS_MD)
    engine.ui_set_next_background_color(engine.color_hex_rgb(THEME_BACKGROUND_PRIMARY_DEFAULT_ALT[state.config.theme]))
    engine.ui_set_next_border_color(engine.color_hex_rgb(THEME_BORDER_PRIMARY_DEFAULT[state.config.theme]))
    text_input_box := engine.ui_row(); {
        engine.ui_padding(8, {.Top, .Bottom})
        engine.ui_padding(10, {.Right, .Left})

        text_input_sig := engine.ui_signal_from_box(text_input_box)
        method_selector_sig: engine.Signal

        {
            engine.ui_set_next_height(engine.ui_fill())
            engine.ui_set_next_width(engine.ui_children_sum(1))
            engine.ui_set_next_flags({.DrawBackground, .MouseClickable})
            engine.ui_set_next_align_y(.Center)
            engine.ui_set_next_border_radius(THEME_BORDER_RADIUS_MD)
            method_selector := engine.ui_row(); {
                engine.ui_padding(8, {.Left, .Right})
                engine.ui_padding(4, {.Top, .Bottom})
                engine.ui_set_next_font_weight(THEME_FONT_WEIGHT_HEADING)
                engine.ui_set_next_font_size(THEME_FONT_SIZE_LABEL)
                engine.ui_set_next_text_color(http_method_color(req.method))
                engine.ui_text(http_method_string(req.method))
                engine.ui_spacer(engine.ui_px(16, 1))
                engine.ui_set_next_text_color(engine.color_hex_rgb(THEME_TEXT_SECONDARY_DEFAULT[state.config.theme]))
                engine.ui_set_next_font_size(THEME_FONT_SIZE_BODY_MD)
                engine.ui_text(ICONS[.Chevron])
            }
            method_selector_sig = engine.ui_signal_from_box(method_selector)
            if engine.ui_clicked(method_selector_sig) {
                log.debug("TODO: Method selector clicked")
            }
            method_selector.background_color = engine.ui_hovering(method_selector_sig) ? engine.color_hex_rgb(THEME_BACKGROUND_PRIMARY_DEFAULT_HOVER[state.config.theme]) : 0x00
        }
        engine.ui_spacer(engine.ui_px(6, 1))
        { // Divider
            engine.ui_set_next_width(engine.ui_px(1, 1))
            engine.ui_set_next_height(engine.ui_px(24, 1))
            engine.ui_set_next_background_color(engine.color_hex_rgb(THEME_BORDER_PRIMARY_DEFAULT[state.config.theme]))
            engine.ui_set_next_flags({.DrawBackground})
            engine.ui_row()
        }

        engine.ui_spacer(engine.ui_px(10, 1))

        text_input_id := engine.ui_make_id(fmt.tprintf("url_input_%d", req.id))

        if engine.ui_clicked(text_input_sig) {
            engine.ui_focus_text_input(text_input_id)
        }

        {
            engine.ui_set_next_font_size(THEME_FONT_SIZE_BODY_SM)
            engine.ui_set_next_text_color(engine.color_hex_rgb(THEME_TEXT_PRIMARY_DEFAULT[state.config.theme]))
            url_len := len(cstring(&req.url[0]))
            engine.ui_set_next_width(engine.ui_fill())
            engine.ui_set_next_height(engine.ui_px(20, 1))
            input_result := engine.ui_text_input(
                text_input_id,
                req.url[:],
                &url_len,
                engine.TextInputOptions{placeholder = "Enter URL or paste text"},
            )
            if input_result.boxes.caret != nil {
                input_result.boxes.caret.background_color = 1
            }
            if input_result.focused {
                text_input_box.border_color = engine.color_hex_rgb(THEME_BORDER_BRAND_DEFAULT)
                text_input_box.border_thickness = 1.5
            }
            if input_result.boxes.placeholder != nil {
                input_result.boxes.placeholder.text_color = engine.color_hex_rgb(THEME_TEXT_PRIMARY_DISABLED[state.config.theme])
            }
            if input_result.boxes.selection != nil {
                input_result.boxes.selection.background_color = engine.color_hex_rgb(THEME_SELECTION_DEFAULT[state.config.theme])
            }
            if input_result.submitted {
                send_request(req)
            }
            if input_result.changed {
                modify_request(req)
            }

            if engine.ui_hovering(text_input_sig) && !engine.ui_hovering(method_selector_sig) {
                engine.set_cursor(.IBEAM)
            }
        }
    }
}

draw_request_parameters_tab :: proc(req: ^Request) {
    engine.ui_set_next_text_color(engine.color_hex_rgb(THEME_TEXT_SECONDARY_DEFAULT[state.config.theme]))
    engine.ui_text_sized("Query Parameters", THEME_FONT_SIZE_BODY_SM)
    engine.ui_spacer(engine.ui_px(10, 1))
    draw_checkbox(&req.query_params_bulk_edit, "Bulk edit")
    if req.query_params_bulk_edit {
        // TODO: if bulk edit, show textarea with key=value pairs
    } else {
        // TODO: query params table
    }
    engine.ui_spacer(engine.ui_px(10, 1))
    if draw_button("Add New", .LinkColored, .Small, left_icon = .Plus) {
        // TODO:
    }

    if len(req.path_params) > 0 {
        engine.ui_spacer(engine.ui_px(10, 1))
        BORDER_H()
        engine.ui_spacer(engine.ui_px(10, 1))
        engine.ui_set_next_text_color(engine.color_hex_rgb(THEME_TEXT_SECONDARY_DEFAULT[state.config.theme]))
        engine.ui_text_sized("Path Parameters", THEME_FONT_SIZE_BODY_SM)
    }
}

draw_request_body_tab :: proc(req: ^Request) {
    engine.ui_set_next_width(engine.ui_fill())
    engine.ui_column(); {
        {
            engine.ui_row(); {
                for type, i in BodyType {
                    if i > 0 {
                        engine.ui_spacer(engine.ui_px(THEME_SPACING_LG, 1))
                    }

                    if draw_radio_button(body_type_string(type), req.body.type == type) {
                        req.body.type = type
                    }
                }
            }
        }

        engine.ui_spacer(engine.ui_px(10, 1))

        // TODO:
        switch req.body.type {
        case .None:
            engine.ui_set_next_width(engine.ui_fill())
            engine.ui_set_next_align_x(.Center)
            engine.ui_row(); {
                engine.ui_set_next_text_color(engine.color_hex_rgb(THEME_TEXT_SECONDARY_DEFAULT[state.config.theme]))
                engine.ui_text_sized("No body will be sent with the request.", THEME_FONT_SIZE_LABEL)
            }
        case .Text:
        case .JSON:
        case .HTML:
        case .XML:
        case .Form:
        case .X_WWW_Form_Urlencoded:
        case .File:
        }
    }
}

draw_request_authorization_tab :: proc(req: ^Request) {
    engine.ui_set_next_text_color(engine.color_hex_rgb(THEME_TEXT_SECONDARY_DEFAULT[state.config.theme]))
    engine.ui_text_sized("Authorization", THEME_FONT_SIZE_BODY_SM)
}

draw_request_headers_tab :: proc(req: ^Request) {
    engine.ui_set_next_text_color(engine.color_hex_rgb(THEME_TEXT_SECONDARY_DEFAULT[state.config.theme]))
    engine.ui_text_sized("Headers", THEME_FONT_SIZE_BODY_SM)
    engine.ui_spacer(engine.ui_px(10, 1))
    draw_checkbox(&req.headers_bulk_edit, "Bulk edit")
    // TODO: query params table
    // TODO: if bulk edit, show textarea with key=value pairs
    engine.ui_spacer(engine.ui_px(10, 1))
    if draw_button("Add New", .LinkColored, .Small, left_icon = .Plus) {
        // TODO:
    }
}

draw_request_main_area :: proc(req: ^Request) {
    available_height := engine.get_window_size().y - TABBAR_HEIGHT - TOPBAR_HEIGHT - 1
    req.height = req.height == 0 ? f32(available_height / 2) : req.height

    engine.ui_set_next_width(engine.ui_fill())
    engine.ui_set_next_height(engine.ui_fill())
    engine.ui_column(); {
        { // Request Area
            engine.ui_set_next_width(engine.ui_fill())
            engine.ui_set_next_height(engine.ui_px(req.height, 1))
            engine.ui_row(); {
                scroll_box: ^engine.Box
                {
                    engine.ui_set_next_width(engine.ui_fill())
                    engine.ui_set_next_height(engine.ui_fill())
                    scroll_box = engine.ui_scroll_column(); {
                        engine.ui_padding(24, {.Left, .Top, .Bottom})
                        engine.ui_padding(12, {.Right})
                        {
                            engine.ui_set_next_width(engine.ui_fill())
                            engine.ui_set_next_height(engine.ui_children_sum(1))
                            engine.ui_set_next_align_y(.Center)
                            engine.ui_row(); {
                                // { // Method and URL Input
                                //     engine.ui_set_next_width(engine.ui_fill())
                                //     engine.ui_set_next_height(engine.ui_px(40, 1))
                                //     engine.ui_set_next_flags({.DrawBackground})
                                //     engine.ui_row()
                                // }
                                engine.ui_set_next_width(engine.ui_fill())
                                draw_url_text_input(req)
                                engine.ui_spacer(engine.ui_px(THEME_SPACING_MD, 1))
                                if draw_button("Send", enabled = len(cstring(&req.url[0])) > 0) {
                                    send_request(req)
                                }
                                engine.ui_spacer(engine.ui_px(THEME_SPACING_SM, 1))
                                if draw_icon_button(.Code, icon_size = 24, variant = .SecondaryGrey, size = .Small, tooltip_text = "Show cURL command") {
                                    // TODO: show curl code dialog
                                }
                            }
                        }

                        engine.ui_spacer(engine.ui_px(10, 1))

                        {
                            engine.ui_set_next_width(engine.ui_fill())
                            engine.ui_set_next_height(engine.ui_children_sum(1))
                            engine.ui_column(); {
                                {
                                    engine.ui_set_next_width(engine.ui_fill())
                                    engine.ui_set_next_height(engine.ui_px(40, 1))
                                    engine.ui_row(); {
                                        for option in reflect.enum_field_names(RequestOptionsTab) {
                                            id := hash.fnv32a(transmute([]byte)engine.ui_hash_part_from_key_string(option))

                                            engine.ui_set_next_width(engine.ui_children_sum(1))
                                            engine.ui_set_next_height(engine.ui_children_sum(1))
                                            engine.ui_column(); {
                                                option_is_active := reflect.enum_string(req.active_options_tab) == option
                                                {
                                                    engine.ui_set_next_width(engine.ui_children_sum(1))
                                                    engine.ui_set_next_height(engine.ui_px(39, 1))
                                                    engine.ui_set_next_align_x(.Center)
                                                    engine.ui_set_next_align_y(.Center)
                                                    engine.ui_set_next_flags({.MouseClickable})
                                                    box := engine.ui_row(id); {
                                                        sig := engine.ui_signal_from_box(box)
                                                        hovering := engine.ui_hovering(sig)

                                                        if hovering {
                                                            engine.set_cursor(.HAND)
                                                        }

                                                        engine.ui_padding(12, {.Left, .Right})
                                                        engine.ui_set_next_text_color(engine.color_hex_rgb(hovering || option_is_active ? THEME_TEXT_PRIMARY_DEFAULT[state.config.theme] : THEME_TEXT_SECONDARY_DEFAULT[state.config.theme]))
                                                        engine.ui_text_sized(option, THEME_FONT_SIZE_BODY_SM)

                                                        if engine.ui_clicked(sig) {
                                                            e, ok := reflect.enum_from_name(RequestOptionsTab, option)
                                                            assert(ok, "Failed to retrieve enum value from enum name for RequestOptionsTab")
                                                            req.active_options_tab = e
                                                        }
                                                    }
                                                }

                                                if option_is_active {
                                                    text_size := engine.ui_text_measure_string(option, THEME_FONT_SIZE_BODY_SM)
                                                    engine.ui_set_next_width(engine.ui_px(text_size.x + 12 * 2, 1))
                                                    engine.ui_set_next_height(engine.ui_px(1, 1))
                                                    engine.ui_set_next_background_color(engine.color_hex_rgb(THEME_BORDER_BRAND_DEFAULT))
                                                    engine.ui_set_next_flags({.DrawBackground})
                                                    engine.ui_row()
                                                }
                                            }
                                        }
                                    }
                                }
                                BORDER_H()
                            }
                        }

                        engine.ui_spacer(engine.ui_px(10, 1))

                        switch req.active_options_tab {
                        case .Parameters:
                            draw_request_parameters_tab(req)
                        case .Body:
                            draw_request_body_tab(req)
                        case .Authorization:
                            draw_request_authorization_tab(req)
                        case .Headers:
                            draw_request_headers_tab(req)
                        }
                    }
                }

                engine.ui_spacer(engine.ui_px(4, 1))
                SCROLLBAR_V(scroll_box)
                engine.ui_spacer(engine.ui_px(2, 1))
            }
        }
        engine.ui_set_next_background_color(engine.color_hex_rgb(THEME_BORDER_PRIMARY_DEFAULT[state.config.theme]))
        interactive, visual := engine.ui_split_divider(.X, &req.height, 1, available_height)
        sig := engine.ui_signal_from_box(interactive)
        if engine.ui_hovering(sig) || engine.ui_dragging(sig) {
            visual.background_color = engine.color_hex_rgb(THEME_BORDER_BRAND_DEFAULT)
        }

        { // Response Area
            #partial switch req.status {
            case .Initial:
                engine.ui_set_next_width(engine.ui_fill())
                engine.ui_set_next_height(engine.ui_fill())
                engine.ui_set_next_align_x(.Center)
                engine.ui_set_next_align_y(.Center)
                engine.ui_column(); {
                    {
                        engine.ui_set_next_background_color(engine.color_hex_rgb(THEME_BACKGROUND_SECONDARY_DEFAULT[state.config.theme]))
                        engine.ui_set_next_width(engine.ui_px(56, 1))
                        engine.ui_set_next_height(engine.ui_px(56, 1))
                        engine.ui_set_next_align_x(.Center)
                        engine.ui_set_next_align_y(.Center)
                        engine.ui_set_next_border_color(engine.color_hex_rgb(THEME_BORDER_PRIMARY_DEFAULT[state.config.theme]))
                        engine.ui_set_next_border_thickness(0.5)
                        engine.ui_set_next_border_radius(9999)
                        engine.ui_set_next_flags({.DrawBackground, .DrawBorder})
                        engine.ui_row(); {
                            engine.ui_set_next_font_size(18)
                            engine.ui_set_next_font_weight(THEME_FONT_WEIGHT_HEADING)
                            engine.ui_set_next_text_color(engine.color_hex_rgb(THEME_TEXT_TERTIARY_DEFAULT[state.config.theme]))
                            engine.ui_text("{}")
                        }
                    }

                    engine.ui_spacer(engine.ui_px(THEME_SPACING_MD, 1))

                    engine.ui_set_next_font_weight(THEME_FONT_WEIGHT_HEADING)
                    engine.ui_text_sized("Response", THEME_FONT_SIZE_BODY_MD)

                    engine.ui_spacer(engine.ui_px(THEME_SPACING_MD, 1))

                    engine.ui_set_next_text_color(engine.color_hex_rgb(THEME_TEXT_SECONDARY_DEFAULT[state.config.theme]))
                    engine.ui_text_sized("Send a request to get a response", THEME_FONT_SIZE_BODY_SM)
                }
            }
        }
    }
}

draw_ui_debug_overlay :: proc() {
    if !state.show_ui_debug_overlay {
        return
    }

    if !state.ui_debug_overlay_pos_initialized {
        state.ui_debug_overlay_pos = {12, 12}
        state.ui_debug_overlay_pos_initialized = true
    }
    
    engine.ui_push_text_color(engine.color_hex_rgb(THEME_TEXT_PRIMARY_DEFAULT[state.config.theme]))
    defer engine.ui_pop_text_color()

    stats := engine.ui_debug_get_frame_stats()

    engine.ui_set_next_fixed_x(state.ui_debug_overlay_pos.x)
    engine.ui_set_next_fixed_y(state.ui_debug_overlay_pos.y)
    engine.ui_set_next_fixed_width(360)
    engine.ui_set_next_height(engine.ui_children_sum(1))
    engine.ui_set_next_border_radius(THEME_BORDER_RADIUS_MD)
    engine.ui_set_next_border_thickness(1)
    engine.ui_set_next_border_color(engine.color_hex_rgb(THEME_BORDER_PRIMARY_DEFAULT[state.config.theme]))
    engine.ui_set_next_background_color(engine.color_hex_rgb(THEME_BACKGROUND_SECONDARY_DEFAULT[state.config.theme]))
    engine.ui_set_next_flags({.DrawBackground, .DrawBorder, .ClipToBounds, .OccludesBelow, .MouseClickable})

    id := engine.ui_make_id("debug_overlay")
    overlay := engine.ui_column(id); {
        sig := engine.ui_signal_from_box(overlay)

        if engine.ui_pressed(sig) {
            mouse_pos := engine.virt_mouse_pos()
            state.ui_debug_overlay_drag_start_mouse = mouse_pos
            // Use persisted overlay position; box.rect is not valid until ui_end_build layout.
            state.ui_debug_overlay_drag_start_pos = state.ui_debug_overlay_pos

            // Keep for compatibility while transitioning drag logic.
            state.ui_debug_overlay_drag_offset.x = mouse_pos.x - state.ui_debug_overlay_pos.x
            state.ui_debug_overlay_drag_offset.y = mouse_pos.y - state.ui_debug_overlay_pos.y
        }

        if engine.ui_dragging(sig) {
            mouse_pos := engine.virt_mouse_pos()
            mouse_delta := mouse_pos - state.ui_debug_overlay_drag_start_mouse
            state.ui_debug_overlay_pos = state.ui_debug_overlay_drag_start_pos + mouse_delta

            window_size := engine.get_window_size()
            overlay_h := max(overlay.rect.max.y-overlay.rect.min.y, 24)
            // Keep the overlay within the visible viewport while dragging.
            state.ui_debug_overlay_pos.x = math.clamp(state.ui_debug_overlay_pos.x, 0, max(window_size.x-360, 0))
            state.ui_debug_overlay_pos.y = math.clamp(state.ui_debug_overlay_pos.y, 0, max(window_size.y-overlay_h, 0))
        }

        engine.ui_padding(10)

        engine.ui_set_next_font_size(13)
        engine.ui_set_next_font_weight(THEME_FONT_WEIGHT_HEADING)
        engine.ui_text("UI Debug Overlay (F3)")

        engine.ui_spacer(engine.ui_px(6, 1))

        engine.ui_set_next_font_size(12)
        engine.ui_set_next_font_weight(THEME_FONT_WEIGHT_BODY)
        engine.ui_text(fmt.tprintf("Rect Draw Cmds: %d", stats.draw_cmd_count))
        engine.ui_text(fmt.tprintf("Rect Instances: %d", stats.draw_instance_count))
        engine.ui_text(fmt.tprintf("Text Cmds: %d", stats.text_cmd_count))
        engine.ui_text(fmt.tprintf("Text Visible: %d", stats.text_cmd_visible_count))
        engine.ui_text(fmt.tprintf("Text Culled: %d", stats.text_cmd_culled_count))
        engine.ui_text(fmt.tprintf("Text Batches: %d", stats.text_batch_count))
        engine.ui_text(fmt.tprintf("Occluded Skips: %d", stats.occluded_box_skip_count))
    }
}

get_config_path :: proc(file: string, allocator := context.allocator) -> (string, bool) {
    config_dir, err := os.user_config_dir(allocator)
    if err != nil {
        log.error("Failed to get user's config directory:", err)

        return "", false
    }
    defer delete(config_dir)

    final_config_path, _ := os.join_path({config_dir, CONFIG_DIR, file}, allocator)

    return final_config_path, true
}

workspaces_schema_version_from_int :: proc(version: int) -> (schema_version: WorkspacesSchemaVersion, ok: bool) {
    switch version {
    case cast(int)WorkspacesSchemaVersion.V0:
        return .V0, true
    case cast(int)WorkspacesSchemaVersion.V1:
        return .V1, true
    case cast(int)WorkspacesSchemaVersion.V2:
        return .V2, true
    }

    return
}

detect_workspaces_schema_version :: proc(data: []byte) -> (version: int, ok: bool) {
    value, parse_err := json.parse(data, parse_integers = true)
    if parse_err != nil {
        return
    }

    defer json.destroy_value(value)

    #partial switch root in value {
    case json.Array:
        // Legacy, unversioned format where collections.json is a top-level array.
        return 0, true
    case json.Object:
        schema_version, has_schema_version := root["schema_version"]
        if has_schema_version {
            if schema_version, schema_ok := schema_version.(json.Integer); schema_ok {
                return cast(int)schema_version, true
            }
        }
    }

    return
}

// v0 stored the raw collections array as the root value.
// v1 wraps it in an object with an explicit schema_version.
migrate_collections_schema_0_to_1 :: proc(data: []byte) -> (migrated_data: []byte, ok: bool) {
    value, parse_err := json.parse(data)
    if parse_err != nil {
        return
    }
    defer json.destroy_value(value)

    if _, is_array := value.(json.Array); !is_array {
        return
    }

    migrated_data = transmute([]byte)fmt.aprintf("%s%s%s", `{"schema_version":1,"collections":`, string(data), `}`)
    return migrated_data, true
}

// v2 changes the formfields to support uploading multiple files in the same key.
// and also adds workspaces.
migrate_collections_schema_1_to_2 :: proc(data: []byte) -> ([]byte, bool) {
    collections_file: CollectionsFile

    err := json.unmarshal(data, &collections_file)
    if err != nil {
        log.error("Failed to unmarshal collections data during migration from v1 to v2:", err)
        return {}, false
    }

    update_collections_form_fields :: proc(collection: ^Collection) {
        for &request in collection.requests {
            if request.body.type == .Form {
                for &field in request.body.structured {
                    value := string(cstring(&field.value[0]))

                    if field.is_file && value != "" {
                        // Move the file path from the value to the new file_paths field and set the value to an empty string.
                        append(&field.file_paths, strings.clone(value))
                        mem.zero_item(&field.value)
                    }
                }
            }
        }

        for child := collection.first; child != nil; child = child.next {
            update_collections_form_fields(child)
        }
    }

    for collection in collections_file.collections {
        update_collections_form_fields(collection)
    }

    collections_file.schema_version = cast(int)WorkspacesSchemaVersion.V2

    workspaces_file := WorkspacesFile{
        schema_version = collections_file.schema_version,
    }

    workspaces_file.workspaces = make([dynamic]Workspace)
    append(&workspaces_file.workspaces, Workspace{
        id = rand.int63(),
        collections = collections_file.collections,
    })
    copy(workspaces_file.workspaces[0].name[:], "Personal Workspace")
    workspaces_file.active_workspace_id = workspaces_file.workspaces[0].id

    migrated_data, marshal_err := json.marshal(workspaces_file)
    if marshal_err != nil {
        log.error("Failed to marshal collections data during migration from v1 to v2:", marshal_err)
        return {}, false
    }

    return migrated_data, true
}

run_workspaces_schema_migrations :: proc(data: []byte, from_version: int) -> (migrated_data: []byte, final_version: int, did_migrate: bool, ok: bool) {
    if from_version > cast(int)CURRENT_WORKSPACES_SCHEMA_VERSION {
        return nil, from_version, false, false
    }

    current_version, known_version := workspaces_schema_version_from_int(from_version)
    if !known_version {
        return nil, from_version, false, false
    }

    working_data := data
    owns_working_data := false

    for current_version != CURRENT_WORKSPACES_SCHEMA_VERSION {
        next_data: []byte
        step_ok := false

        switch current_version {
        case .V0:
            next_data, step_ok = migrate_collections_schema_0_to_1(working_data)
            if step_ok {
                current_version = .V1
            }
        case .V1:
            next_data, step_ok = migrate_collections_schema_1_to_2(working_data)
            if step_ok {
                current_version = .V2
            }
        case .V2:
            // NOTE: This is only reachable if CURRENT_COLLECTIONS_SCHEMA_VERSION
            // moves ahead without adding a migration step from V2.
        }

        if !step_ok {
            if owns_working_data {
                delete(working_data)
            }

            return nil, cast(int)current_version, did_migrate, false
        }

        did_migrate = true
        if owns_working_data {
            delete(working_data)
        }

        working_data = next_data
        owns_working_data = true
    }

    if owns_working_data {
        return working_data, cast(int)current_version, did_migrate, true
    }

    return nil, cast(int)current_version, false, true
}

save_workspaces :: proc() {
    // TODO: support updating/saving collections of an instance

    if state.config.active_instance == nil {
        config_path, ok := get_config_path("collections.json")
        if !ok {
            log.error("Failed to retrieve local collections path")
            return
        }
        defer delete(config_path)

        existing_collections_json, read_err := os.read_entire_file(config_path, context.allocator)
        defer delete(existing_collections_json)
        if read_err == nil {
            backup_path := fmt.aprintf("%s.bak", config_path)
            defer delete(backup_path)

            backup_file, backup_open_err := os.open(backup_path, {.Write, .Trunc, .Create}, os.Permissions_Read_All + {.Write_User})
            defer os.close(backup_file)
            if backup_open_err != nil {
                log.error("Failed to save collections backup:", backup_open_err)
                return
            }

            _, backup_write_err := os.write(backup_file, existing_collections_json)
            if backup_write_err != nil {
                log.error("Failed to save collections backup:", backup_write_err)
                return
            }
        } else if read_err != .Not_Exist {
            log.error("Failed to save collections backup:", read_err)
            return
        }

        workspaces_file := WorkspacesFile{
            schema_version = cast(int)CURRENT_WORKSPACES_SCHEMA_VERSION,
            active_workspace_id = state.workspaces[state.active_workspace_index].id,
            workspaces = state.workspaces,
        }

        workspaces_json, err := json.marshal(workspaces_file)
        defer delete(workspaces_json)
        if err != nil {
            log.error("Failed to save collections:", err)
            return
        }

        file, open_err := os.open(config_path, {.Write, .Trunc, .Create}, os.Permissions_Read_All + {.Write_User})
        defer os.close(file)
        if open_err != nil {
            log.error("Failed to save collections:", open_err)
            return
        }

        _, write_err := os.write(file, workspaces_json)
        if write_err != nil {
            log.error("Failed to save collections:", write_err)
            return
        }
    }
}

load_workspaces :: proc() {
    // Free the entire collection arena since we will be loading different collections.
    free_all(state.collection_allocator)
    // unmarshal allocates a new dynamic array every time so we delete it every time.
    for workspace in state.workspaces {
        delete(workspace.collections)
    }
    delete(state.workspaces)

    config_path, ok := get_config_path("collections.json")
    if !ok {
        log.error("Failed to retrieve local workspaces path")
        return
    }
    defer delete(config_path)

    data, read_err := os.read_entire_file(config_path, context.allocator)
    if read_err != nil {
        if read_err != .Not_Exist {
            log.error("Failed to load local workspaces:", read_err)
        }

        return
    }
    defer delete(data)

    schema_version, has_schema_version := detect_workspaces_schema_version(data)
    if !has_schema_version {
        log.error("Failed to detect local workspaces schema version")
        return
    }

    migrated_data, final_schema_version, did_migrate, migration_ok := run_workspaces_schema_migrations(data, schema_version)
    if !migration_ok {
        return
    }

    defer if did_migrate {
        delete(migrated_data)
    }

    final_data := data
    if did_migrate {
        final_data = migrated_data
    }

    workspaces_file: WorkspacesFile
    json_err := json.unmarshal(final_data, &workspaces_file)
    if json_err != nil {
        log.error("Failed to parse workspaces:", json_err)
        return
    }

    if workspaces_file.schema_version != final_schema_version {
        log.errorf("Failed to parse workspaces: expected schema version v%d but got v%d", final_schema_version, workspaces_file.schema_version)
        return
    }

    state.workspaces = workspaces_file.workspaces
    for workspace, i in state.workspaces {
        if workspace.id == workspaces_file.active_workspace_id {
            state.active_workspace_index = i
            break
        }
    }

    if did_migrate {
        log.infof("Migrated local workspaces schema from v%d to v%d", schema_version, final_schema_version)
        save_workspaces()
    }

    log.infof("Successfully loaded workspaces from \"%s\"", config_path)
}

load_config_and_initialize_state :: proc() {
    ensure(virtual.arena_init_static(&state.collection_arena) == nil, "Failed to allocate memory")
    state.collection_allocator = virtual.arena_allocator(&state.collection_arena)

    config_path, ok := get_config_path("config.json")
    if !ok {
        // For now return from the function since ZII initializes our config to sensible defaults.
        // and we load the local collections if any.
        load_workspaces()
        return
    }
    defer delete(config_path)

    config_dir := os.dir(config_path)
    os.make_directory_all(config_dir)
    data, read_err := os.read_entire_file(config_path, context.allocator)
    if read_err != nil {
        if read_err != .Not_Exist {
            log.error("Failed to load configuration file:", read_err)
        }

        // Load local collections even if the config doesn't exist.
        load_workspaces()
        return
    }
    defer delete(data)

    json_err := json.unmarshal(data, &state.config)
    if json_err != nil {
        log.error("Failed to parse config:", json_err)
        return
    }

    log.infof("Successfully loaded configuration from \"%s\"", config_path)

    if state.config.active_instance == nil {
        load_workspaces()
    }

    state.active_tab_index = -1
    state.config.sidebar_width = math.max(state.config.sidebar_width, 350)
}

save_config :: proc() {
    config_path, ok := get_config_path("config.json")
    if !ok {
        log.error("Failed to retrieve config path")
        return
    }
    defer delete(config_path)

    config_json, err := json.marshal(state.config)
    defer delete(config_json)
    if err != nil {
        log.error("Failed to save config:", err)
        return
    }

    file, open_err := os.open(config_path, {.Write, .Trunc, .Create}, os.Permissions_Read_All + {.Write_User})
    defer os.close(file)
    if open_err != nil {
        log.error("Failed to save config:", open_err)
        return
    }

    _, write_err := os.write(file, config_json)
    if write_err != nil {
        log.error("Failed to save config:", write_err)
        return
    }
}

// Assumes dst is initialized/valid but we want to overwrite its data with src data
// It clears dst data before copying
copy_request_data :: proc(dst: ^Request, src: ^Request) {
    mem.zero_item(&dst.name)
    copy(dst.name[:], src.name[:])
    dst.method = src.method
    mem.zero_item(&dst.url)
    copy(dst.url[:], src.url[:])

    delete(dst.query_params)
    dst.query_params = make([dynamic]QueryParam, len(src.query_params))
    copy(dst.query_params[:], src.query_params[:])

    delete(dst.headers)
    dst.headers = make([dynamic]RequestHeader, len(src.headers))
    copy(dst.headers[:], src.headers[:])

    for key, param in dst.path_params {
        delete(param.indices)
        delete(key)
    }
    delete(dst.path_params)
    dst.path_params = make(map[string]PathParam)

    for key, &value in src.path_params {
        new_value := PathParam{}
        copy(new_value.value[:], value.value[:])
        new_value.indices = make([dynamic]PathParamIndex, len(value.indices))
        copy(new_value.indices[:], value.indices[:])
        dst.path_params[strings.clone(key)] = new_value
    }

    strings.builder_destroy(&dst.body.text)
    for field in dst.body.structured {
        for file_path in field.file_paths {
            delete(file_path)
        }
        delete(field.file_paths)
    }
    delete(dst.body.structured)
    delete(dst.body.binary_path)

    dst.body.type = src.body.type

    dst.body.text = strings.builder_make_len(strings.builder_len(src.body.text))
    copy(dst.body.text.buf[:], src.body.text.buf[:])

    dst.body.structured = make([dynamic]FormField, len(src.body.structured))
    copy(dst.body.structured[:], src.body.structured[:])
    for field, i in src.body.structured {
        dst.body.structured[i].file_paths = make([dynamic]string, len(field.file_paths))
        for file_path, j in field.file_paths {
            dst.body.structured[i].file_paths[j] = strings.clone(file_path)
        }
    }

    dst.body.binary_path = strings.clone(src.body.binary_path)

    // Update auth
    dst.auth.type = src.auth.type
    mem.zero_item(&dst.auth.basic_username)
    mem.zero_item(&dst.auth.basic_password)
    mem.zero_item(&dst.auth.bearer_token)
    mem.zero_item(&dst.auth.api_key_key)
    mem.zero_item(&dst.auth.api_key_value)
    copy(dst.auth.basic_username[:], src.auth.basic_username[:])
    copy(dst.auth.basic_password[:], src.auth.basic_password[:])
    copy(dst.auth.bearer_token[:], src.auth.bearer_token[:])
    copy(dst.auth.api_key_key[:], src.auth.api_key_key[:])
    copy(dst.auth.api_key_value[:], src.auth.api_key_value[:])
    dst.auth.api_key_add_to = src.auth.api_key_add_to

    dst.collection = src.collection
    dst.modification_hash = src.modification_hash
    dst.is_modified = false
    dst.active_options_tab = src.active_options_tab
    dst.active_response_tab = src.active_response_tab
}

destroy_request :: proc(request: ^Request) {
    strings.builder_destroy(&request.body.text)
    for &field in request.body.structured {
        for file_path in field.file_paths {
            delete(file_path)
        }
        delete(field.file_paths)
    }
    delete(request.body.structured)
    delete(request.body.binary_path)

    delete(request.query_params)
    delete(request.headers)
    for header in request.response.headers {
        delete(header.key)
        delete(header.value)
    }
    delete(request.response.headers)
    for key, param in request.path_params {
        delete(param.indices)
        delete(key)
    }
    delete(request.path_params)
    strings.builder_destroy(&request.response.data)
    strings.builder_destroy(&request.response.pretty_data)
    strings.builder_destroy(&request.response.raw_data)
    strings.builder_destroy(&request.response.raw_pretty_data)
    if request.curl_handle != nil {
        curl.easy_cleanup(request.curl_handle)
    }
    if request.curl_headers != nil {
        curl.slist_free_all(request.curl_headers)
    }
    if request.form != nil {
        curl.mime_free(request.form)
    }

    // if request.query_params_model != nil {
    //     qt.qobject_delete(cast(^qt.QObject)request.query_params_model)
    // }
    // if request.headers_model != nil {
    //     qt.qobject_delete(cast(^qt.QObject)request.headers_model)
    // }
    // if request.path_params_model != nil {
    //     qt.qobject_delete(cast(^qt.QObject)request.path_params_model)
    // }
    // if request.response_headers_model != nil {
    //     qt.qobject_delete(cast(^qt.QObject)request.response_headers_model)
    // }
    // if request.body_form_model != nil {
    //     qt.qobject_delete(cast(^qt.QObject)request.body_form_model)
    // }
}

destroy_collection :: proc(collection: ^Collection) {
    for &request in collection.requests {
        destroy_request(&request)
    }
    delete(collection.requests)

    for child := collection.first; child != nil; child = child.next {
        destroy_collection(child)
    }

    free(collection, state.collection_allocator)
}

cleanup :: proc() {
    for workspace in state.workspaces {
        for collection in workspace.collections {
            destroy_collection(collection)
        }
    }
    for tab_item in state.tabs {
        switch v in tab_item {
        case ^Request:
            destroy_request(v)
            free(v)
        case ^Collection:
            // no-op
        case ^Environment:
            // TODO:?
        }
    }
    delete(state.tabs)
    delete(state.workspaces)
}

update_url_from_query_params :: proc(request: ^Request) {
    merged_url := strings.builder_make_len_cap(0, 8192)
    defer strings.builder_destroy(&merged_url)
    split_url := strings.split_n(string(cstring(&request.url[0])), "?", 2)
    defer delete(split_url)
    url_no_queries := split_url[0]
    strings.write_string(&merged_url, url_no_queries)

    if len(request.query_params) > 0 {
        strings.write_byte(&merged_url, '?')
    }
    should_write_ampersand := false
    for &param in request.query_params {
        key := string(cstring(&param.key[0]))
        if param.disabled || key == "" {
            continue
        }
        if should_write_ampersand {
            strings.write_byte(&merged_url, '&')
        }

        should_write_ampersand = true

        strings.write_string(&merged_url, key)
        val := string(cstring(&param.value[0]))
        if val != "" {
            strings.write_byte(&merged_url, '=')
            strings.write_string(&merged_url, val)
        }
    }

    mem.zero_item(&request.url)
    copy(request.url[:], strings.to_string(merged_url))
}

is_path_param_char :: #force_inline proc "contextless" (b: u8) -> bool {
    return (b >= 'a' && b <= 'z') ||
           (b >= 'A' && b <= 'Z') ||
           (b >= '0' && b <= '9') ||
           b == '_' || b == '-'
}

parse_path_params_from_url :: proc(request: ^Request) {
    old_path_params := request.path_params
    new_path_params := make(map[string]PathParam)

    url_copy := strings.clone_from_cstring(cstring(&request.url[0]))
    defer delete(url_copy)
    path_end := len(url_copy)
    for i := 0; i < len(url_copy); i += 1 {
        if url_copy[i] == '?' || url_copy[i] == '#' {
            path_end = i
            break
        }
    }

    path := url_copy[:path_end]

    for i := 0; i < len(path); i += 1 {
        // Match /:param style placeholders
        if path[i] == ':' && i > 0 && path[i-1] == '/' {
            j := i + 1
            for j < len(path) && is_path_param_char(path[j]) {
                j += 1
            }

            if j > i + 1 {
                key := path[i+1:j]
                index := PathParamIndex{start = i, end = j}

                if p, ok := new_path_params[key]; ok {
                    append(&p.indices, index)
                    new_path_params[key] = p
                } else {
                    p := PathParam{}
                    p.indices = make([dynamic]PathParamIndex)
                    append(&p.indices, index)

                    if old, ok := old_path_params[key]; ok {
                        copy(p.value[:], string(cstring(&old.value[0])))
                    }

                    new_path_params[strings.clone(key)] = p
                }

                i = j - 1
                continue
            }
        }
    }

    for key, param in old_path_params {
        delete(param.indices)
        delete(key)
    }
    delete(old_path_params)

    request.path_params = new_path_params
}

request_marshaller :: proc(w: io.Writer, v: any, opt: ^json.Marshal_Options) -> json.Marshal_Error {
    if v == nil {
        return nil
    }

    io.write_byte(w, '{') or_return

    v_info := runtime.type_info_base(type_info_of(v.id))
    if info, ok := v_info.variant.(runtime.Type_Info_Struct); ok {
        for name, i in info.names[:info.field_count] {
            tag_val := reflect.struct_tag_get(reflect.Struct_Tag(info.tags[i]), "json")
            if tag_val == "-" {
                continue
            }

            if i != 0 {
                io.write_byte(w, ',') or_return
            }

            if tag_val != "" {
                io.write_quoted_string(w, tag_val) or_return
            } else {
                io.write_quoted_string(w, name) or_return
            }
            io.write_byte(w, ':') or_return

            type := info.types[i]
            data := rawptr(uintptr(v.data) + info.offsets[i])

            switch type.id {
            case i64:
                id := ((cast(^i64)(data))^)
                io.write_i64(w, id) or_return
            case [128]u8:
                cstr := ((cast(^[128]u8)(data))^)
                str := strings.clone_from_cstring(cstring(&cstr[0]))
                defer delete(str)
                io.write_quoted_string(w, str) or_return
            case HttpMethod:
                method := ((cast(^HttpMethod)(data))^)
                method_str, ok := reflect.enum_name_from_value(method)
                if !ok {
                    return .Unsupported_Type
                }
                method_str_upper := strings.to_upper(method_str)
                defer delete(method_str_upper)
                io.write_quoted_string(w, method_str_upper) or_return
            case [4096]u8:
                cstr := ((cast(^[4096]u8)(data))^)
                str := strings.clone_from_cstring(cstring(&cstr[0]))
                defer delete(str)
                io.write_quoted_string(w, str) or_return
            case [dynamic]RequestHeader:
                headers := ((cast(^[dynamic]RequestHeader)(data))^)
                opt: json.Marshal_Options

                json.marshal_to_writer(w, headers, &opt) or_return
            case [dynamic]QueryParam:
                params := ((cast(^[dynamic]QueryParam)(data))^)
                opt: json.Marshal_Options

                json.marshal_to_writer(w, params, &opt) or_return
            case map[string]PathParam:
                params := ((cast(^map[string]PathParam)(data))^)
                opt: json.Marshal_Options

                io.write_byte(w, '{') or_return

                i := 0
                for key, value in params {
                    if i != 0 {
                        io.write_byte(w, ',') or_return
                    }
                    io.write_quoted_string(w, key) or_return
                    io.write_byte(w, ':') or_return

                    json.marshal_to_writer(w, value, &opt) or_return
                }

                io.write_byte(w, '}') or_return
            case RequestBody:
                body := ((cast(^RequestBody)(data))^)

                if body.type == .None {
                    io.write_string(w, "null") or_return
                    continue
                }

                io.write_string(w, `{"type":`) or_return
                io.write_uint(w, cast(uint)body.type) or_return
                io.write_byte(w, ',') or_return

                /// Text
                io.write_string(w, `"text":`) or_return
                io.write_quoted_string(w, string(cstring(raw_data(string(body.text.buf[:]))))) or_return
                io.write_byte(w, ',') or_return

                /// Structured
                io.write_string(w, `"structured":`) or_return
                opt: json.Marshal_Options
                json.marshal_to_writer(w, body.structured, &opt) or_return
                io.write_byte(w, ',') or_return

                /// Binary
                io.write_string(w, `"file":`) or_return
                io.write_quoted_string(w, body.binary_path) or_return

                io.write_byte(w, '}') or_return
            case Authorization:
                auth := ((cast(^Authorization)(data))^)
                io.write_string(w, `{"type":`) or_return
                io.write_uint(w, cast(uint)auth.type) or_return
                io.write_byte(w, ',') or_return

                io.write_string(w, `"basic_username":`) or_return
                io.write_quoted_string(w, string(cstring(&auth.basic_username[0]))) or_return
                io.write_byte(w, ',') or_return

                io.write_string(w, `"basic_password":`) or_return
                io.write_quoted_string(w, string(cstring(&auth.basic_password[0]))) or_return
                io.write_byte(w, ',') or_return

                io.write_string(w, `"bearer_token":`) or_return
                io.write_quoted_string(w, string(cstring(&auth.bearer_token[0]))) or_return
                io.write_byte(w, ',') or_return

                io.write_string(w, `"bearer_prefix":`) or_return
                io.write_quoted_string(w, string(cstring(&auth.bearer_prefix[0]))) or_return
                io.write_byte(w, ',') or_return

                io.write_string(w, `"api_key_key":`) or_return
                io.write_quoted_string(w, string(cstring(&auth.api_key_key[0]))) or_return
                io.write_byte(w, ',') or_return

                io.write_string(w, `"api_key_value":`) or_return
                io.write_quoted_string(w, string(cstring(&auth.api_key_value[0]))) or_return
                io.write_byte(w, ',') or_return

                io.write_string(w, `"api_key_add_to":`) or_return
                io.write_uint(w, cast(uint)auth.api_key_add_to) or_return

                io.write_string(w, "}") or_return
            case ^Collection:
                collection := ((cast(^^Collection)(data))^)
                if collection == nil {
                    io.write_string(w, "null") or_return
                } else {
                    io.write_i64(w, collection.id) or_return
                }
            }
        }
    }

    io.write_byte(w, '}') or_return

    return nil
}

workspace_marshaller :: proc(w: io.Writer, v: any, opt: ^json.Marshal_Options) -> json.Marshal_Error {
    if v == nil {
        return nil
    }

    io.write_byte(w, '{') or_return

    v_info := runtime.type_info_base(type_info_of(v.id))
    if info, ok := v_info.variant.(runtime.Type_Info_Struct); ok {
        for name, i in info.names[:info.field_count] {
            tag_val := reflect.struct_tag_get(reflect.Struct_Tag(info.tags[i]), "json")
            if tag_val == "-" {
                continue
            }

            if i != 0 {
                io.write_byte(w, ',') or_return
            }

            if tag_val != "" {
                io.write_quoted_string(w, tag_val) or_return
            } else {
                io.write_quoted_string(w, name) or_return
            }
            io.write_byte(w, ':') or_return

            type := info.types[i]
            data := rawptr(uintptr(v.data) + info.offsets[i])

            switch type.id {
            case i64:
                id := ((cast(^i64)(data))^)
                io.write_i64(w, id) or_return
            case [128]u8:
                cstr := ((cast(^[128]u8)(data))^)
                str := strings.clone_from_cstring(cstring(&cstr[0]))
                defer delete(str)
                io.write_quoted_string(w, str) or_return
            case [dynamic]^Collection:
                collections := ((cast(^[dynamic]^Collection)(data))^)
                opt: json.Marshal_Options

                json.marshal_to_writer(w, collections, &opt) or_return
            case [dynamic]Environment:
                environments := ((cast(^[dynamic]Environment)(data))^)
                opt: json.Marshal_Options

                json.marshal_to_writer(w, environments, &opt) or_return
            }
        }
    }

    io.write_byte(w, '}') or_return

    return nil
}

collection_marshaller :: proc(w: io.Writer, v: any, opt: ^json.Marshal_Options) -> json.Marshal_Error {
    if v == nil {
        return nil
    }

    io.write_byte(w, '{') or_return

    v_info := type_info_of(v.id)
    if info, ok := v_info.variant.(runtime.Type_Info_Pointer); ok {
        elem := runtime.type_info_base(info.elem)

        if info, ok := elem.variant.(runtime.Type_Info_Struct); ok {
            first_index := -1
            // Double indirection since we're marshalling a pointer
            collection_addr := cast(^uintptr)v.data

            for name, i in info.names[:info.field_count] {
                if name == "first" {
                    first_index = i
                }

                tag_val := reflect.struct_tag_get(reflect.Struct_Tag(info.tags[i]), "json")
                if tag_val == "-" {
                    continue
                }

                if i != 0 {
                    io.write_byte(w, ',') or_return
                }

                io.write_quoted_string(w, name) or_return
                io.write_byte(w, ':') or_return

                type := info.types[i]
                data := rawptr(uintptr(collection_addr^) + info.offsets[i])

                switch type.id {
                case i64:
                    id := ((cast(^i64)(data))^)
                    io.write_i64(w, id) or_return
                case [128]u8:
                    cstr := ((cast(^[128]u8)(data))^)
                    str := strings.clone_from_cstring(cstring(&cstr[0]))
                    defer delete(str)
                    io.write_quoted_string(w, str) or_return
                case [dynamic]Request:
                    req := ((cast(^[dynamic]Request)(data))^)
                    opt: json.Marshal_Options
                    json.marshal_to_writer(w, req, &opt) or_return
                case Authorization:
                    auth := ((cast(^Authorization)(data))^)
                    io.write_string(w, `{"type":`) or_return
                    io.write_uint(w, cast(uint)auth.type) or_return
                    io.write_byte(w, ',') or_return

                    io.write_string(w, `"basic_username":`) or_return
                    io.write_quoted_string(w, string(cstring(&auth.basic_username[0]))) or_return
                    io.write_byte(w, ',') or_return

                    io.write_string(w, `"basic_password":`) or_return
                    io.write_quoted_string(w, string(cstring(&auth.basic_password[0]))) or_return
                    io.write_byte(w, ',') or_return

                    io.write_string(w, `"bearer_token":`) or_return
                    io.write_quoted_string(w, string(cstring(&auth.bearer_token[0]))) or_return
                    io.write_byte(w, ',') or_return

                    io.write_string(w, `"bearer_prefix":`) or_return
                    io.write_quoted_string(w, string(cstring(&auth.bearer_prefix[0]))) or_return
                    io.write_byte(w, ',') or_return

                    io.write_string(w, `"api_key_key":`) or_return
                    io.write_quoted_string(w, string(cstring(&auth.api_key_key[0]))) or_return
                    io.write_byte(w, ',') or_return

                    io.write_string(w, `"api_key_value":`) or_return
                    io.write_quoted_string(w, string(cstring(&auth.api_key_value[0]))) or_return
                    io.write_byte(w, ',') or_return

                    io.write_string(w, `"api_key_add_to":`) or_return
                    io.write_uint(w, cast(uint)auth.api_key_add_to) or_return

                    io.write_string(w, "}") or_return
                }
            }

            io.write_byte(w, ',') or_return
            io.write_quoted_string(w, "children") or_return
            io.write_byte(w, ':') or_return
            io.write_byte(w, '[') or_return

            first_child := rawptr(uintptr(collection_addr^) + info.offsets[first_index])
            if runtime.memory_compare_zero(first_child, size_of(rawptr)) != 0 {
                first := (cast(^^Collection)(first_child))^
                for child := first; child != nil; child = child.next {
                    // NOTE: Use the address of the child to match the double indirection we do
                    // at the top. Otherwise we're reading garbage.
                    collection_marshaller(w, any{&child, v.id}, opt) or_return
                }
            }

            io.write_byte(w, ']') or_return
        }
    }

    io.write_byte(w, '}') or_return

    return nil
}

environment_marshaller :: proc(w: io.Writer, v: any, opt: ^json.Marshal_Options) -> json.Marshal_Error {
    if v == nil {
        return nil
    }

    io.write_byte(w, '{') or_return

    v_info := runtime.type_info_base(type_info_of(v.id))
    if info, ok := v_info.variant.(runtime.Type_Info_Struct); ok {
        for name, i in info.names[:info.field_count] {
            tag_val := reflect.struct_tag_get(reflect.Struct_Tag(info.tags[i]), "json")
            if tag_val == "-" {
                continue
            }

            if i != 0 {
                io.write_byte(w, ',') or_return
            }

            if tag_val != "" {
                io.write_quoted_string(w, tag_val) or_return
            } else {
                io.write_quoted_string(w, name) or_return
            }
            io.write_byte(w, ':') or_return

            type := info.types[i]
            data := rawptr(uintptr(v.data) + info.offsets[i])

            switch type.id {
            case i64:
                id := ((cast(^i64)(data))^)
                io.write_i64(w, id) or_return
            case [128]u8:
                cstr := ((cast(^[128]u8)(data))^)
                str := strings.clone_from_cstring(cstring(&cstr[0]))
                defer delete(str)
                io.write_quoted_string(w, str) or_return
            case map[string]string:
                vars := ((cast(^map[string]string)(data))^)
                opt: json.Marshal_Options

                json.marshal_to_writer(w, vars, &opt) or_return
            case [dynamic]EnvironmentVariableField:
                vars := ((cast(^[dynamic]EnvironmentVariableField)(data))^)
                opt: json.Marshal_Options

                json.marshal_to_writer(w, vars, &opt) or_return
            }
        }
    }

    io.write_byte(w, '}') or_return

    return nil
}

environment_variable_field_marshaller :: proc(w: io.Writer, v: any, opt: ^json.Marshal_Options) -> json.Marshal_Error {
    if v == nil {
        return nil
    }

    io.write_byte(w, '{') or_return

    v_info := runtime.type_info_base(type_info_of(v.id))
    if info, ok := v_info.variant.(runtime.Type_Info_Struct); ok {
        for name, i in info.names[:info.field_count] {
            tag_val := reflect.struct_tag_get(reflect.Struct_Tag(info.tags[i]), "json")
            if tag_val == "-" {
                continue
            }

            if i != 0 {
                io.write_byte(w, ',') or_return
            }

            if tag_val != "" {
                io.write_quoted_string(w, tag_val) or_return
            } else {
                io.write_quoted_string(w, name) or_return
            }
            io.write_byte(w, ':') or_return

            type := info.types[i]
            data := rawptr(uintptr(v.data) + info.offsets[i])

            switch type.id {
            case [128]u8:
                cstr := ((cast(^[128]u8)(data))^)
                str := strings.clone_from_cstring(cstring(&cstr[0]))
                defer delete(str)
                io.write_quoted_string(w, str) or_return
            case [1024]u8:
                cstr := ((cast(^[1024]u8)(data))^)
                str := strings.clone_from_cstring(cstring(&cstr[0]))
                defer delete(str)
                io.write_quoted_string(w, str) or_return
            case bool:
                b := ((cast(^bool)(data))^)
                io.write_string(w, b ? "true" : "false") or_return
            }
        }
    }

    io.write_byte(w, '}') or_return

    return nil
}

form_field_marshaller :: proc(w: io.Writer, v: any, opt: ^json.Marshal_Options) -> json.Marshal_Error {
    if v == nil {
        return nil
    }

    io.write_byte(w, '{') or_return

    v_info := runtime.type_info_base(type_info_of(v.id))
    if info, ok := v_info.variant.(runtime.Type_Info_Struct); ok {
        for name, i in info.names[:info.field_count] {
            tag_val := reflect.struct_tag_get(reflect.Struct_Tag(info.tags[i]), "json")
            if tag_val == "-" {
                continue
            }

            if i != 0 {
                io.write_byte(w, ',') or_return
            }

            if tag_val != "" {
                io.write_quoted_string(w, tag_val) or_return
            } else {
                io.write_quoted_string(w, name) or_return
            }
            io.write_byte(w, ':') or_return

            type := info.types[i]
            data := rawptr(uintptr(v.data) + info.offsets[i])

            switch type.id {
            case i64:
                id := ((cast(^i64)(data))^)
                io.write_i64(w, id) or_return
            case bool:
                disabled := ((cast(^bool)(data))^)
                io.write_string(w, "true" if disabled else "false") or_return
            case [128]u8:
                cstr := ((cast(^[128]u8)(data))^)
                str := strings.clone_from_cstring(cstring(&cstr[0]))
                defer delete(str)
                io.write_quoted_string(w, str) or_return
            case [512]u8:
                cstr := ((cast(^[512]u8)(data))^)
                str := strings.clone_from_cstring(cstring(&cstr[0]))
                defer delete(str)
                io.write_quoted_string(w, str) or_return
            case [1024]u8:
                cstr := ((cast(^[1024]u8)(data))^)
                str := strings.clone_from_cstring(cstring(&cstr[0]))
                defer delete(str)
                io.write_quoted_string(w, str) or_return
            case [dynamic]string:
                arr := ((cast(^[dynamic]string)(data))^)
                opt: json.Marshal_Options

                json.marshal_to_writer(w, arr, &opt) or_return
            }
        }
    }

    io.write_byte(w, '}') or_return

    return nil
}

key_value_marshaller :: proc(w: io.Writer, v: any, opt: ^json.Marshal_Options) -> json.Marshal_Error {
    if v == nil {
        return nil
    }

    io.write_byte(w, '{') or_return

    v_info := runtime.type_info_base(type_info_of(v.id))
    if info, ok := v_info.variant.(runtime.Type_Info_Struct); ok {
        for name, i in info.names[:info.field_count] {
            tag_val := reflect.struct_tag_get(reflect.Struct_Tag(info.tags[i]), "json")
            if tag_val == "-" {
                continue
            }

            if i != 0 {
                io.write_byte(w, ',') or_return
            }

            if tag_val != "" {
                io.write_quoted_string(w, tag_val) or_return
            } else {
                io.write_quoted_string(w, name) or_return
            }
            io.write_byte(w, ':') or_return

            type := info.types[i]
            data := rawptr(uintptr(v.data) + info.offsets[i])

            switch type.id {
            case i64:
                id := ((cast(^i64)(data))^)
                io.write_i64(w, id) or_return
            case bool:
                disabled := ((cast(^bool)(data))^)
                io.write_string(w, "true" if disabled else "false")
            case [128]u8:
                cstr := ((cast(^[128]u8)(data))^)
                str := strings.clone_from_cstring(cstring(&cstr[0]))
                defer delete(str)
                io.write_quoted_string(w, str) or_return
            case [512]u8:
                cstr := ((cast(^[512]u8)(data))^)
                str := strings.clone_from_cstring(cstring(&cstr[0]))
                defer delete(str)
                io.write_quoted_string(w, str) or_return
            case [1024]u8:
                cstr := ((cast(^[1024]u8)(data))^)
                str := strings.clone_from_cstring(cstring(&cstr[0]))
                defer delete(str)
                io.write_quoted_string(w, str) or_return
            }
        }
    }

    io.write_byte(w, '}') or_return

    return nil
}

path_param_marshaller :: proc(w: io.Writer, v: any, opt: ^json.Marshal_Options) -> json.Marshal_Error {
    if v == nil {
        return nil
    }

    io.write_byte(w, '{') or_return

    v_info := runtime.type_info_base(type_info_of(v.id))
    if info, ok := v_info.variant.(runtime.Type_Info_Struct); ok {
        for name, i in info.names[:info.field_count] {
            tag_val := reflect.struct_tag_get(reflect.Struct_Tag(info.tags[i]), "json")
            if tag_val == "-" {
                continue
            }

            if i != 0 {
                io.write_byte(w, ',') or_return
            }

            if tag_val != "" {
                io.write_quoted_string(w, tag_val) or_return
            } else {
                io.write_quoted_string(w, name) or_return
            }
            io.write_byte(w, ':') or_return

            type := info.types[i]
            data := rawptr(uintptr(v.data) + info.offsets[i])

            switch type.id {
            case [dynamic]PathParamIndex:
                arr := ((cast(^[dynamic]PathParamIndex)(data))^)
                opt: json.Marshal_Options

                json.marshal_to_writer(w, arr, &opt) or_return
            case [1024]u8:
                cstr := ((cast(^[1024]u8)(data))^)
                str := strings.clone_from_cstring(cstring(&cstr[0]))
                defer delete(str)
                io.write_quoted_string(w, str) or_return
            }
        }
    }

    io.write_byte(w, '}') or_return

    return nil
}

get_collection :: proc(val: json.Object) -> (collection: ^Collection, err: json.Unmarshal_Error) {
    id := val["id"].(json.Integer)
    name := val["name"].(json.String)
    requests := val["requests"].(json.Array)
    children := val["children"].(json.Array)

    a_err: runtime.Allocator_Error
    collection, a_err = new(Collection, state.collection_allocator)
    #partial switch a_err {
    case nil: // no-op
    case .Out_Of_Memory:
        return nil, .Out_Of_Memory
    case:
        return nil, .Invalid_Allocator
    }
    collection.id = id
    collection.requests, a_err = make([dynamic]Request, state.collection_allocator)
    #partial switch a_err {
    case nil: // no-op
    case .Out_Of_Memory:
        return nil, .Out_Of_Memory
    case:
        return nil, .Invalid_Allocator
    }
    copy(collection.name[:], name[:])

    // Unmarshal collection-level auth (optional, for backwards compatibility with older saves)
    #partial switch auth in val["auth"] {
    case json.Object:
        auth_type := auth["type"].(json.Integer)
        auth_basic_username := auth["basic_username"].(json.String)
        auth_basic_password := auth["basic_password"].(json.String)
        auth_bearer_token := auth["bearer_token"].(json.String)
        auth_api_key_key := auth["api_key_key"].(json.String)
        auth_api_key_value := auth["api_key_value"].(json.String)
        auth_api_key_add_to := auth["api_key_add_to"].(json.Integer)

        if auth_type < cast(i64)AuthType.InheritFromParent || auth_type > cast(i64)AuthType.ApiKey {
            log.warn("Unknown collection auth type. defaulting to InheritFromParent")
            auth_type = cast(i64)AuthType.InheritFromParent
        }
        if auth_api_key_add_to < cast(i64)ApiKeyAddTo.Header || auth_api_key_add_to > cast(i64)ApiKeyAddTo.QueryParam {
            log.warn("Unknown API key add to value. defaulting to Header")
            auth_api_key_add_to = cast(i64)ApiKeyAddTo.Header
        }
        collection.auth.type = cast(AuthType)auth_type
        collection.auth.api_key_add_to = cast(ApiKeyAddTo)auth_api_key_add_to
        copy(collection.auth.basic_username[:], auth_basic_username)
        copy(collection.auth.basic_password[:], auth_basic_password)
        copy(collection.auth.bearer_token[:], auth_bearer_token)
        copy(collection.auth.api_key_key[:], auth_api_key_key)
        copy(collection.auth.api_key_value[:], auth_api_key_value)

        // Backwards compatible: older saves may not have bearer_prefix
        #partial switch bp in auth["bearer_prefix"] {
        case json.String:
            copy(collection.auth.bearer_prefix[:], bp)
        }
    }

    for req in requests {
        request_map := req.(json.Object)
        request: Request
        // TODO: don't assume every key exists.
        // Some keys are fine to not exist, we can just warn and continue instead of crashing.
        // Important keys like id should probably always exist though.
        // or people could just not mess with the damn config, idk.
        // But I feel like headers should probably be something that we can ignore
        // if it doesn't exist since it's not that important.
        id := request_map["id"].(json.Integer)
        name := request_map["name"].(json.String)
        method := request_map["method"].(json.String)
        url := request_map["url"].(json.String)
        collection_id := request_map["collection_id"]
        body := request_map["body"]

        request.id = id
        copy(request.name[:], name[:])
        // Using pascal case is a quick hack to get a capitalized method
        method, a_err = strings.to_pascal_case(method)
        defer delete(method)
        #partial switch a_err {
        case nil: // no-op
        case .Out_Of_Memory:
            return nil, .Out_Of_Memory
        case:
            return nil, .Invalid_Allocator
        }
        method_value, ok := reflect.enum_from_name(HttpMethod, method)
        if ok {
            request.method = method_value
        } else {
            log.error("Failed to retrieve request method from config. Defaulting to GET")
        }
        copy(request.url[:], url[:])

        #partial switch v in body {
        case json.Null: // no-op
        case json.Object:
            body_map := v
            body_type := body_map["type"].(json.Integer)
            body_value := body_map["value"]

            if body_type < cast(i64)BodyType.None || body_type > cast(i64)BodyType.File {
                log.warn("Unknown request body type. defaulting to None")
            } else {
                request.body.type = cast(BodyType)body_type

                body_text := body_map["text"].(json.String)
                body_structured := body_map["structured"].(json.Array)
                body_binary := body_map["file"].(json.String)

                /// Text
                request.body.text = strings.builder_make_len_cap(0, 1024)
                strings.write_string(&request.body.text, body_text)

                /// Structured
                for field in body_structured {
                    field := field.(json.Object)
                    field_id := field["id"].(json.Integer)
                    field_key := field["key"].(json.String)
                    field_value := field["value"].(json.String)
                    field_file_paths, file_paths_ok := field["file_paths"].(json.Array)
                    field_is_file := field["is_file"].(json.Boolean)
                    field_content_type, ct_ok := field["content_type"]
                    field_disabled, disabled_ok := field["disabled"]

                    f := FormField{}
                    f.id = field_id
                    f.is_file = field_is_file
                    if disabled_ok {
                        f.disabled = field_disabled.(json.Boolean)
                    }
                    copy(f.key[:], field_key)
                    copy(f.value[:], field_value)
                    if ct_ok {
                        copy(f.content_type[:], field_content_type.(json.String))
                    }

                    if file_paths_ok {
                        for file_path in field_file_paths {
                            file_path := file_path.(json.String)
                            append(&f.file_paths, strings.clone(file_path))
                        }
                    }

                    append(&request.body.structured, f)
                }

                /// Binary
                request.body.binary_path = strings.clone(body_binary)
            }
        }

        #partial switch headers in request_map["headers"] {
        case json.Array:
            for header in headers {
                header := header.(json.Object)
                header_id := header["id"].(json.Integer)
                header_name := header["key"].(json.String)
                header_value := header["value"].(json.String)
                header_disabled, disabled_ok := header["disabled"]

                h := RequestHeader{}
                h.id = header_id
                if disabled_ok {
                    h.disabled = header_disabled.(json.Boolean)
                }
                copy(h.key[:], header_name[:])
                copy(h.value[:], header_value[:])
                append(&request.headers, h)
            }
        }

        #partial switch auth in request_map["auth"] {
        case json.Object:
            auth_type := auth["type"].(json.Integer)
            auth_basic_username := auth["basic_username"].(json.String)
            auth_basic_password := auth["basic_password"].(json.String)
            auth_bearer_token := auth["bearer_token"].(json.String)
            auth_api_key_key := auth["api_key_key"].(json.String)
            auth_api_key_value := auth["api_key_value"].(json.String)
            auth_api_key_add_to := auth["api_key_add_to"].(json.Integer)

            if auth_type < cast(i64)AuthType.InheritFromParent || auth_type > cast(i64)AuthType.ApiKey {
                log.warn("Unknown auth type. defaulting to InheritFromParent")
                auth_type = cast(i64)AuthType.InheritFromParent
            }
            if auth_api_key_add_to < cast(i64)ApiKeyAddTo.Header || auth_api_key_add_to > cast(i64)ApiKeyAddTo.QueryParam {
                log.warn("Unknown API key add to value. defaulting to Header")
                auth_api_key_add_to = cast(i64)ApiKeyAddTo.Header
            }
            request.auth.type = cast(AuthType)auth_type
            request.auth.api_key_add_to = cast(ApiKeyAddTo)auth_api_key_add_to
            copy(request.auth.basic_username[:], auth_basic_username)
            copy(request.auth.basic_password[:], auth_basic_password)
            copy(request.auth.bearer_token[:], auth_bearer_token)
            copy(request.auth.api_key_key[:], auth_api_key_key)
            copy(request.auth.api_key_value[:], auth_api_key_value)

            // Backwards compatible: older saves may not have bearer_prefix
            #partial switch bp in auth["bearer_prefix"] {
            case json.String:
                copy(request.auth.bearer_prefix[:], bp)
            }
        }

        // NOTE: switching here avoids crashing on type assertions if the collection
        // belongs to an older version.
        #partial switch params in request_map["query_params"] {
        case json.Array:
            for param in params {
                param := param.(json.Object)
                param_id := param["id"].(json.Integer)
                param_name := param["key"].(json.String)
                param_value := param["value"].(json.String)
                param_disabled := param["disabled"].(json.Boolean)

                p := QueryParam{}
                p.id = param_id
                p.disabled = param_disabled
                copy(p.key[:], param_name)
                copy(p.value[:], param_value)
                append(&request.query_params, p)
            }
        }

        #partial switch params in request_map["path_params"] {
        case json.Object:
            for key, value in params {
                param := value.(json.Object)
                param_value := param["value"].(json.String)
                indices := param["indices"].(json.Array)

                p := PathParam{}
                copy(p.value[:], param_value)
                for index in indices {
                    index := index.(json.Object)
                    start := index["start"].(json.Integer)
                    end := index["end"].(json.Integer)
                    append(&p.indices, PathParamIndex{start = cast(int)start, end = cast(int)end})
                }

                request.path_params[strings.clone(key)] = p
            }
        }

        // NOTE: make sure to always load whatever gets hashed BEFORE calculating and setting the hash.
        request.modification_hash = hash_request(&request)

        #partial switch v in collection_id {
        case json.Null:
            // Do nothing because request.collection is already nil
        case json.Integer:
            request.collection = collection
        }

        _, a_err = append(&collection.requests, request)
        #partial switch a_err {
        case nil: // no-op
        case .Out_Of_Memory:
            return nil, .Out_Of_Memory
        case:
            return nil, .Invalid_Allocator
        }
    }

    for child in children {
        // NOTE: no need to call json.destroy_value() on the child here
        // because get_collection() already does that
        child := child.(json.Object)
        child_collection := get_collection(child) or_return

        child_collection.parent = collection

        if collection.first == nil {
            collection.first = child_collection
            collection.last = child_collection
        } else {
            child_collection.prev = collection.last
            collection.last.next = child_collection
            collection.last = child_collection
        }
    }

    return
}

workspace_unmarshaller :: proc(p: ^json.Parser, v: any) -> json.Unmarshal_Error {
    val := json.parse_object(p) or_return
    defer json.destroy_value(val)

    get_workspace :: proc(val: json.Object) -> (workspace: Workspace, err: json.Unmarshal_Error) {
        id := val["id"].(json.Integer)
        name := val["name"].(json.String)
        collections := val["collections"].(json.Array)
        environments, env_ok := val["environments"].(json.Array)
        selected_environment_id, has_selected_environment_id := val["selected_environment_id"]

        workspace.id = id
        workspace.selected_environment_id = -1
        copy(workspace.name[:], name[:])

        if has_selected_environment_id {
            workspace.selected_environment_id = selected_environment_id.(json.Integer) or_else -1
        }

        for collection in collections {
            collection := collection.(json.Object)
            child_collection := get_collection(collection) or_return
            append(&workspace.collections, child_collection)
        }

        if env_ok {
            for e in environments {
                env := e.(json.Object)
                id := env["id"].(json.Integer)
                name := env["name"].(json.String)
                variables := env["variables"].(json.Array)

                environment := Environment{id = id}
                copy(environment.name[:], name)

                for f in variables {
                    field := f.(json.Object)
                    var_key := field["variable"].(json.String)
                    var_value := field["value"].(json.String)

                    var_field := EnvironmentVariableField{}
                    copy(var_field.variable[:], var_key)
                    copy(var_field.value[:], var_value)

                    var_enabled, has_enabled := field["enabled"]
                    if has_enabled {
                        var_field.enabled = var_enabled.(json.Boolean) or_else true
                    } else {
                        var_field.enabled = true
                    }

                    append(&environment.variables, var_field)
                }

                append(&workspace.environments, environment)
            }
        }

        return
    }

    if val, ok := val.(json.Object); ok {
        workspace := get_workspace(val) or_return

        switch &dst in v {
        case Workspace:
            dst = workspace
        }
    }

    return nil
}

collection_unmarshaller :: proc(p: ^json.Parser, v: any) -> json.Unmarshal_Error {
    val := json.parse_object(p) or_return
    defer json.destroy_value(val)

    if val, ok := val.(json.Object); ok {
        collection := get_collection(val) or_return

        switch &dst in v {
        case ^Collection:
            dst = collection
        }
    }

    return nil
}

resolve_collection_auth :: proc(collection: ^Collection) -> Authorization {
    for c := collection; c != nil; c = c.parent {
        if c.auth.type != .InheritFromParent {
            return c.auth
        }
    }

    // No concrete auth found in the collection chain, so this resolves to no auth.
    return Authorization{}
}

resolve_request_auth :: proc(request: ^Request) -> Authorization {
    if request.auth.type != .InheritFromParent {
        return request.auth
    }

    return resolve_collection_auth(request.collection)
}

trimmed_auth :: proc(auth: Authorization) -> Authorization {
    auth_local := auth
    trimmed := auth

    username := strings.trim_space(string(cstring(&auth_local.basic_username[0])))
    password := strings.trim_space(string(cstring(&auth_local.basic_password[0])))
    bearer_token := strings.trim_space(string(cstring(&auth_local.bearer_token[0])))
    bearer_prefix := strings.trim_space(string(cstring(&auth_local.bearer_prefix[0])))
    api_key_key := strings.trim_space(string(cstring(&auth_local.api_key_key[0])))
    api_key_value := strings.trim_space(string(cstring(&auth_local.api_key_value[0])))

    mem.zero_item(&trimmed.basic_username)
    mem.zero_item(&trimmed.basic_password)
    mem.zero_item(&trimmed.bearer_token)
    mem.zero_item(&trimmed.bearer_prefix)
    mem.zero_item(&trimmed.api_key_key)
    mem.zero_item(&trimmed.api_key_value)

    copy(trimmed.basic_username[:], username)
    copy(trimmed.basic_password[:], password)
    copy(trimmed.bearer_token[:], bearer_token)
    copy(trimmed.bearer_prefix[:], bearer_prefix)
    copy(trimmed.api_key_key[:], api_key_key)
    copy(trimmed.api_key_value[:], api_key_value)

    return trimmed
}

resolve_effective_auth :: proc(tab: TabItem) -> Authorization {
    switch v in tab {
    case ^Request:
        return trimmed_auth(resolve_request_auth(v))
    case ^Collection:
        return trimmed_auth(v.auth)
    case ^Environment:
        return Authorization{}
    }

    return Authorization{}
}

resolve_auth_environment_variables :: proc(auth: Authorization) -> (resolved: Authorization) {
    resolved = auth

    basic_username_bytes := auth.basic_username
    basic_username, changed_basic_username := resolve_environment_variables(string(cstring(&basic_username_bytes[0])))
    defer if changed_basic_username {
        delete(basic_username)
    }
    if changed_basic_username {
        mem.zero_item(&resolved.basic_username)
        copy(resolved.basic_username[:], basic_username)
    }

    basic_password_bytes := auth.basic_password
    basic_password, changed_basic_password := resolve_environment_variables(string(cstring(&basic_password_bytes[0])))
    defer if changed_basic_password {
        delete(basic_password)
    }
    if changed_basic_password {
        mem.zero_item(&resolved.basic_password)
        copy(resolved.basic_password[:], basic_password)
    }

    bearer_token_bytes := auth.bearer_token
    bearer_token, changed_bearer_token := resolve_environment_variables(string(cstring(&bearer_token_bytes[0])))
    defer if changed_bearer_token {
        delete(bearer_token)
    }
    if changed_bearer_token {
        mem.zero_item(&resolved.bearer_token)
        copy(resolved.bearer_token[:], bearer_token)
    }

    api_key_key_bytes := auth.api_key_key
    api_key_key, changed_api_key_key := resolve_environment_variables(string(cstring(&api_key_key_bytes[0])))
    defer if changed_api_key_key {
        delete(api_key_key)
    }
    if changed_api_key_key {
        mem.zero_item(&resolved.api_key_key)
        copy(resolved.api_key_key[:], api_key_key)
    }

    api_key_value_bytes := auth.api_key_value
    api_key_value, changed_api_key_value := resolve_environment_variables(string(cstring(&api_key_value_bytes[0])))
    defer if changed_api_key_value {
        delete(api_key_value)
    }
    if changed_api_key_value {
        mem.zero_item(&resolved.api_key_value)
        copy(resolved.api_key_value[:], api_key_value)
    }

    return resolved
}

current_workspace_selected_environment_index :: proc() -> i32 {
    if state.active_workspace_index < 0 || state.active_workspace_index >= len(state.workspaces) {
        return -1
    }

    workspace := &state.workspaces[state.active_workspace_index]
    if workspace.selected_environment_id < 0 {
        return -1
    }

    for i in 0..<len(workspace.environments) {
        if workspace.environments[i].id == workspace.selected_environment_id {
            return cast(i32)i
        }
    }

    return -1
}

current_workspace_selected_environment_name :: proc() -> cstring {
    index := current_workspace_selected_environment_index()
    if index < 0 {
        return "No Environment"
    }

    workspace := &state.workspaces[state.active_workspace_index]
    return cstring(&workspace.environments[index].name[0])
}

current_workspace_selected_environment :: proc() -> ^Environment {
    index := current_workspace_selected_environment_index()
    if index < 0 {
        return nil
    }

    workspace := &state.workspaces[state.active_workspace_index]
    return &workspace.environments[index]
}

lookup_environment_variable_value :: proc(key: string) -> (string, bool) {
    environment := current_workspace_selected_environment()
    if environment == nil {
        return "", false
    }

    trimmed_key := strings.trim_space(key)
    if trimmed_key == "" {
        return "", false
    }

    for i := cast(i32)len(environment.variables) - 1; i >= 0; i -= 1 {
        field := &environment.variables[i]
        if !field.enabled {
            continue
        }

        variable_key := strings.trim_space(string(cstring(&field.variable[0])))
        if variable_key == trimmed_key {
            value := string(cstring(&field.value[0]))
            if strings.trim_space(value) == "" {
                continue
            }

            return value, true
        }
    }

    return "", false
}

build_final_request_url :: proc(request: ^Request, effective_auth: Authorization, allocator := context.allocator) -> string {
    final_url := strings.builder_make_len_cap(0, 1024, allocator)

    request_url := strings.trim_space(string(cstring(&request.url[0])))
    resolved_request_url, request_url_changed := resolve_environment_variables(request_url, allocator)
    defer if request_url_changed {
        delete(resolved_request_url)
    }
    if request_url_changed {
        request_url = resolved_request_url
    }

    path_end := len(request_url)
    for i := 0; i < len(request_url); i += 1 {
        if request_url[i] == '?' || request_url[i] == '#' {
            path_end = i
            break
        }
    }

    url_up_to_query := request_url[:path_end]
    path_start := 0
    scheme_sep := strings.index(url_up_to_query, "://")
    if scheme_sep >= 0 {
        after_scheme := scheme_sep + 3
        slash_pos := strings.index_byte(url_up_to_query[after_scheme:], '/')
        if slash_pos < 0 {
            strings.write_string(&final_url, url_up_to_query)
        } else {
            path_start = after_scheme + slash_pos
            strings.write_string(&final_url, url_up_to_query[:path_start])

            path := url_up_to_query[path_start:]
            encoded_path := percent_encode_url_path_preserving_slashes(path, allocator)
            defer delete(encoded_path)
            strings.write_string(&final_url, encoded_path)
        }
    } else {
        path := url_up_to_query[path_start:]
        encoded_path := percent_encode_url_path_preserving_slashes(path, allocator)
        defer delete(encoded_path)
        strings.write_string(&final_url, encoded_path)
    }

    for key, &param in request.path_params {
        if cstring(&param.value[0]) == "" {
            continue
        }

        placeholder := fmt.aprintf(":%s", key)
        defer delete(placeholder)
        path_param_value := string(cstring(&param.value[0]))
        resolved_path_param_value, path_param_changed := resolve_environment_variables(path_param_value, allocator)
        defer if path_param_changed {
            delete(resolved_path_param_value)
        }
        if path_param_changed {
            path_param_value = resolved_path_param_value
        }

        percent_encoded_value := percent_encode_url_path(path_param_value, allocator)
        defer delete(percent_encoded_value)
        strings.builder_replace_all(&final_url, placeholder, percent_encoded_value)
    }

    effective_api_key_key_bytes := effective_auth.api_key_key
    effective_api_key_key := strings.trim_space(string(cstring(&effective_api_key_key_bytes[0])))
    should_write_ampersand := false
    if len(request.query_params) > 0 || (effective_auth.type == .ApiKey && effective_auth.api_key_add_to == .QueryParam && effective_api_key_key != "") {
        strings.write_byte(&final_url, '?')
    }

    if effective_auth.type == .ApiKey && effective_auth.api_key_add_to == .QueryParam {
        api_value_bytes := effective_auth.api_key_value
        api_value := string(cstring(&api_value_bytes[0]))
        if effective_api_key_key != "" {
            should_write_ampersand = true

            key_encoded := percent_encode_query_param_component(effective_api_key_key, allocator)
            defer delete(key_encoded)
            strings.write_string(&final_url, key_encoded)

            if api_value != "" {
                value_encoded := percent_encode_query_param_component(api_value, allocator)
                defer delete(value_encoded)
                strings.write_byte(&final_url, '=')
                strings.write_string(&final_url, value_encoded)
            }
        }
    }

    api_key_query_key := ""
    if effective_auth.type == .ApiKey && effective_auth.api_key_add_to == .QueryParam {
        api_key_query_key = effective_api_key_key
    }

    for &query in request.query_params {
        key := string(cstring(&query.key[0]))
        value := string(cstring(&query.value[0]))

        resolved_key, key_changed := resolve_environment_variables(key, allocator)
        defer if key_changed {
            delete(resolved_key)
        }
        if key_changed {
            key = resolved_key
        }

        key = strings.trim_space(key)

        resolved_value, value_changed := resolve_environment_variables(value, allocator)
        defer if value_changed {
            delete(resolved_value)
        }
        if value_changed {
            value = resolved_value
        }

        if query.disabled || key == "" || (api_key_query_key != "" && api_key_query_key == key) {
            continue
        }
        if should_write_ampersand {
            strings.write_byte(&final_url, '&')
        }

        should_write_ampersand = true

        key_encoded := percent_encode_query_param_component(key, allocator)
        defer delete(key_encoded)
        strings.write_string(&final_url, key_encoded)

        if value != "" {
            value_encoded := percent_encode_query_param_component(value, allocator)
            defer delete(value_encoded)
            strings.write_byte(&final_url, '=')
            strings.write_string(&final_url, value_encoded)
        }
    }

    return strings.to_string(final_url)
}

resolve_environment_variables :: proc(raw: string, allocator := context.allocator) -> (resolved: string, changed: bool) {
    if raw == "" {
        return "", false
    }

    has_placeholder := false
    for i := 0; i+1 < len(raw); i += 1 {
        if raw[i] == '{' && raw[i+1] == '{' {
            has_placeholder = true
            break
        }
    }

    if !has_placeholder || current_workspace_selected_environment() == nil {
        return "", false
    }

    sb := strings.builder_make_len_cap(0, len(raw), allocator)
    defer if !changed {
        strings.builder_destroy(&sb)
    }

    write_start := 0
    i := 0
    for i < len(raw)-1 {
        if raw[i] == '{' && raw[i+1] == '{' {
            close_index := -1
            j := i + 2
            for j < len(raw)-1 {
                if raw[j] == '}' && raw[j+1] == '}' {
                    close_index = j
                    break
                }
                j += 1
            }

            if close_index < 0 {
                break
            }

            token := strings.trim_space(raw[i+2:close_index])
            if token != "" {
                value, ok := lookup_environment_variable_value(token)
                if ok {
                    if write_start < i {
                        strings.write_string(&sb, raw[write_start:i])
                    }

                    strings.write_string(&sb, value)
                    changed = true
                    i = close_index + 2
                    write_start = i
                    continue
                }
            }

            i = close_index + 2
            continue
        }

        i += 1
    }

    if !changed {
        return "", false
    }

    if write_start < len(raw) {
        strings.write_string(&sb, raw[write_start:])
    }

    return strings.to_string(sb), true
}

send_request :: proc(request: ^Request) {
    // request_index := qt.qvariant_toInt(argv[1])
    // assert(request_index >= 0 && request_index < cast(i32)len(state.tabs))

    // request := state.tabs[request_index].(^Request)

    if request.status == .Running {
        return
        // break signal_switch
    }

    handle := curl.easy_init()
    request.curl_handle = handle
    request.status = .Running
    request.response.status_code = 0
    request.response.time.total = 0
    request.response.size = 0

    for header in request.response.headers {
        delete(header.key)
        delete(header.value)
    }
    clear(&request.response.headers)
    // if request.response_headers_model != nil {
    //     qt.qabstractitemmodel_beginResetModel(cast(^qt.QAbstractItemModel)request.response_headers_model)
    //     qt.qabstractitemmodel_endResetModel(cast(^qt.QAbstractItemModel)request.response_headers_model)
    // }

    // { // Let Qt know we updated the status
    //     roles := [?]i32{
    //         cast(i32)RequestListRoles.Status,
    //     }

    //     parent := qt.qmodelindex_create()
    //     defer qt.qmodelindex_delete(parent)
    //     index := qt.qabstractlistmodel_index(requests_list_model, request_index, 0, parent)
    //     defer qt.qmodelindex_delete(index)
    //     qt.qabstractitemmodel_dataChanged(cast(^qt.QAbstractItemModel)requests_list_model, index, index, raw_data(roles[:]), cast(i32)len(roles))
    // }

    if request.response.pretty_data.buf == nil {
        strings.builder_init(&request.response.pretty_data)
    } else {
        strings.builder_reset(&request.response.pretty_data)
    }

    if request.response.raw_data.buf == nil {
        strings.builder_init(&request.response.raw_data)
    } else {
        strings.builder_reset(&request.response.raw_data)
    }

    if request.response.raw_pretty_data.buf == nil {
        strings.builder_init(&request.response.raw_pretty_data)
    } else {
        strings.builder_reset(&request.response.raw_pretty_data)
    }

    request.response.has_escaped_unicode = false
    request.response.show_escaped_unicode = false

    if request.response.data.buf == nil {
        strings.builder_init(&request.response.data)
    } else {
        strings.builder_reset(&request.response.data)
    }

    effective_auth := resolve_auth_environment_variables(trimmed_auth(resolve_request_auth(request)))
    effective_api_key_key := string(cstring(&effective_auth.api_key_key[0]))
    effective_api_key_key_lower := strings.to_lower(effective_api_key_key)
    defer delete(effective_api_key_key_lower)

    for &header in request.headers {
        if header.disabled {
            continue
        }

        // Use the cstring's length to terminate at the first null byte
        // otherwise the join ends up with multiple null bytes between the key and value
        // and that causes the eventual cstring conversion to terminate at the first null byte
        // which is after the key.

        key_cstr := cstring(&header.key[0])
        value_cstr := cstring(&header.value[0])
        key := string(header.key[:len(key_cstr)])
        value := string(header.value[:len(value_cstr)])

        resolved_key, key_changed := resolve_environment_variables(key)
        defer if key_changed {
            delete(resolved_key)
        }
        if key_changed {
            key = resolved_key
        }

        resolved_value, value_changed := resolve_environment_variables(value)
        defer if value_changed {
            delete(resolved_value)
        }
        if value_changed {
            value = resolved_value
        }

        // TODO: I still have to make a final decision on this. Maybe even make it configurable or something?
        // Skip the user-set content-type header in favor of the request body type
        key_lower := strings.to_lower(key)
        defer delete(key_lower)
        if key_lower == "content-type" && request.body.type != .None {
            continue
        }
        if key_lower == "authorization" && effective_auth.type != .InheritFromParent && effective_auth.type != .ApiKey && effective_auth.type != .NoAuth {
            continue
        }
        if effective_auth.type == .ApiKey && effective_auth.api_key_add_to == .Header && key_lower == effective_api_key_key_lower {
            continue
        }

        final_header_str := strings.join({key, value}, ": ")
        defer delete(final_header_str)
        header_value := strings.clone_to_cstring(final_header_str)
        defer delete(header_value)
        request.curl_headers = curl.slist_append(request.curl_headers, header_value)
    }

    body_text := strings.to_string(request.body.text)
    resolved_body_text, body_text_changed := resolve_environment_variables(body_text)
    defer if body_text_changed {
        delete(resolved_body_text)
    }
    if body_text_changed {
        body_text = resolved_body_text
    }

    // --- Authorization header generation ---
    auth_switch: switch effective_auth.type {
    case .InheritFromParent:
    case .NoAuth:
        // no-op
    case .Basic:
        username := string(cstring(&effective_auth.basic_username[0]))
        password := string(cstring(&effective_auth.basic_password[0]))
        if username != "" || password != "" {
            credentials := fmt.aprintf("%s:%s", username, password)
            defer delete(credentials)
            encoded := base64.encode(transmute([]u8)credentials)
            defer delete(encoded)
            auth_header := fmt.aprintf("Authorization: Basic %s", encoded)
            defer delete(auth_header)
            auth_cstr := strings.clone_to_cstring(auth_header)
            defer delete(auth_cstr)
            request.curl_headers = curl.slist_append(request.curl_headers, auth_cstr)
        }
    case .Token:
        token := string(cstring(&effective_auth.bearer_token[0]))
        if token != "" {
            prefix := string(cstring(&effective_auth.bearer_prefix[0]))
            if prefix == "" {
                prefix = "Bearer"
            }
            auth_header := fmt.aprintf("Authorization: %s %s", prefix, token)
            defer delete(auth_header)
            auth_cstr := strings.clone_to_cstring(auth_header)
            defer delete(auth_cstr)
            request.curl_headers = curl.slist_append(request.curl_headers, auth_cstr)
        }
    case .ApiKey:
        key := effective_api_key_key
        value := string(cstring(&effective_auth.api_key_value[0]))
        if key != "" && effective_auth.api_key_add_to == .Header {
            api_header := fmt.aprintf("%s: %s", key, value)
            defer delete(api_header)
            api_cstr := strings.clone_to_cstring(api_header)
            defer delete(api_cstr)
            request.curl_headers = curl.slist_append(request.curl_headers, api_cstr)
        }
    }

    body_switch: switch request.body.type {
    case .None:
        // Do nothing
    case .Text:
        content_type := cstring("Content-Type: text/plain")
        request.curl_headers = curl.slist_append(request.curl_headers, content_type)
        ensure(curl.easy_setopt(handle, .POSTFIELDSIZE, len(body_text)) == .E_OK)
        ensure(curl.easy_setopt(handle, .COPYPOSTFIELDS, body_text) == .E_OK)
    case .JSON:
        content_type := cstring("Content-Type: application/json")
        request.curl_headers = curl.slist_append(request.curl_headers, content_type)
        ensure(curl.easy_setopt(handle, .POSTFIELDSIZE, len(body_text)) == .E_OK)
        ensure(curl.easy_setopt(handle, .COPYPOSTFIELDS, body_text) == .E_OK)
    case .XML:
        content_type := cstring("Content-Type: text/xml")
        request.curl_headers = curl.slist_append(request.curl_headers, content_type)
        ensure(curl.easy_setopt(handle, .POSTFIELDSIZE, len(body_text)) == .E_OK)
        ensure(curl.easy_setopt(handle, .COPYPOSTFIELDS, body_text) == .E_OK)
    case .HTML:
        content_type := cstring("Content-Type: text/html")
        request.curl_headers = curl.slist_append(request.curl_headers, content_type)
        ensure(curl.easy_setopt(handle, .POSTFIELDSIZE, len(body_text)) == .E_OK)
        ensure(curl.easy_setopt(handle, .COPYPOSTFIELDS, body_text) == .E_OK)
    case .X_WWW_Form_Urlencoded:
        content_type := cstring("Content-Type: application/x-www-form-urlencoded")
        request.curl_headers = curl.slist_append(request.curl_headers, content_type)
        data: strings.Builder
        defer strings.builder_destroy(&data)

        for &field, i in request.body.structured {
            if field.disabled {
                continue
            }
            if i != 0 {
                strings.write_byte(&data, '&')
            }

            field_key := string(cstring(raw_data(field.key[:])))
            resolved_field_key, field_key_changed := resolve_environment_variables(field_key)
            defer if field_key_changed {
                delete(resolved_field_key)
            }
            if field_key_changed {
                field_key = resolved_field_key
            }

            field_value := string(cstring(raw_data(field.value[:])))
            resolved_field_value, field_value_changed := resolve_environment_variables(field_value)
            defer if field_value_changed {
                delete(resolved_field_value)
            }
            if field_value_changed {
                field_value = resolved_field_value
            }

            encoded_key := percent_encode_query_param_component(field_key)
            defer delete(encoded_key)
            encoded_value := percent_encode_query_param_component(field_value)
            defer delete(encoded_value)
            encoded_field := fmt.aprintf("%s=%s", encoded_key, encoded_value)
            defer delete(encoded_field)

            strings.write_string(&data, encoded_field)
        }
        // Tell curl to copy the post fields since we delete the builder at the end of the scope
        ensure(curl.easy_setopt(handle, .COPYPOSTFIELDS, strings.to_string(data)) == .E_OK)
    case .Form:
        content_type := cstring("Content-Type: multipart/form-data")
        request.curl_headers = curl.slist_append(request.curl_headers, content_type)

        form := curl.mime_init(handle)
        ensure(form != nil)
        request.form = form

        for &field in request.body.structured {
            if field.disabled {
                continue
            }

            if field.is_file {
                field_key := string(cstring(raw_data(field.key[:])))
                resolved_field_key, field_key_changed := resolve_environment_variables(field_key)
                defer if field_key_changed {
                    delete(resolved_field_key)
                }
                if field_key_changed {
                    field_key = resolved_field_key
                }

                field_content_type := string(cstring(&field.content_type[0]))
                resolved_field_content_type, field_content_type_changed := resolve_environment_variables(field_content_type)
                defer if field_content_type_changed {
                    delete(resolved_field_content_type)
                }
                if field_content_type_changed {
                    field_content_type = resolved_field_content_type
                }

                for file_path in field.file_paths {
                    if file_path == "" {
                        log.warn("Empty file path in form field, skipping. This should never happen. Please report this to the developers.")
                        continue
                    }

                    part := curl.mime_addpart(form)
                    field_key_cstr := strings.clone_to_cstring(field_key)
                    defer delete(field_key_cstr)
                    curl.mime_name(part, field_key_cstr)

                    // TODO: curl does a little bit of recognition of the content type based on a few heuristics
                    // In the future we should implement our own "advanced" heuristics to guess the content type
                    // See: https://curl.se/libcurl/c/curl_mime_type.html
                    if field_content_type != "" {
                        field_content_type_cstr := strings.clone_to_cstring(field_content_type)
                        defer delete(field_content_type_cstr)
                        curl.mime_type(part, field_content_type_cstr)
                    }

                    // TODO: check the file exists before trying to send it and show an error if it doesn't
                    // the error should be displayed to the user in the UI in addition to logging it

                    file_path_cstr := strings.clone_to_cstring(file_path)
                    defer delete(file_path_cstr)
                    code := curl.mime_filedata(part, cast(rawptr)file_path_cstr)
                    if code != .E_OK {
                        // TODO: display the error in the UI in addition to logging it
                        log.errorf("Failed to send file: %v", code)
                    }
                }
            } else {
                field_key := string(cstring(raw_data(field.key[:])))
                resolved_field_key, field_key_changed := resolve_environment_variables(field_key)
                defer if field_key_changed {
                    delete(resolved_field_key)
                }
                if field_key_changed {
                    field_key = resolved_field_key
                }

                field_value := string(cstring(raw_data(field.value[:])))
                resolved_field_value, field_value_changed := resolve_environment_variables(field_value)
                defer if field_value_changed {
                    delete(resolved_field_value)
                }
                if field_value_changed {
                    field_value = resolved_field_value
                }

                field_content_type := string(cstring(&field.content_type[0]))
                resolved_field_content_type, field_content_type_changed := resolve_environment_variables(field_content_type)
                defer if field_content_type_changed {
                    delete(resolved_field_content_type)
                }
                if field_content_type_changed {
                    field_content_type = resolved_field_content_type
                }

                part := curl.mime_addpart(form)
                field_key_cstr := strings.clone_to_cstring(field_key)
                defer delete(field_key_cstr)
                curl.mime_name(part, field_key_cstr)

                // TODO: curl does a little bit of recognition of the content type based on a few heuristics
                // In the future we should implement our own "advanced" heuristics to guess the content type
                // See: https://curl.se/libcurl/c/curl_mime_type.html
                if field_content_type != "" {
                    field_content_type_cstr := strings.clone_to_cstring(field_content_type)
                    defer delete(field_content_type_cstr)
                    curl.mime_type(part, field_content_type_cstr)
                }

                curl.mime_data(part, raw_data(field_value), cast(uint)len(field_value))
            }
        }

        ensure(curl.easy_setopt(handle, .MIMEPOST, form) == .E_OK)
    case .File:
        if request.body.binary_path == "" {
            break body_switch
        }

        // TODO: auto-detect what the file is and set the content-type based on that?
        content_type := cstring("Content-Type: application/octet-stream")
        request.curl_headers = curl.slist_append(request.curl_headers, content_type)
        file, err := os.open(request.body.binary_path)

        if err != nil {
            request.status = .Error

            // roles := [?]i32{
            //     cast(i32)RequestListRoles.Status,
            //     cast(i32)RequestListRoles.ResponseData,
            // }

            // parent := qt.qmodelindex_create()
            // defer qt.qmodelindex_delete(parent)
            // index := qt.qabstractlistmodel_index(requests_list_model, request_index, 0, parent)
            // defer qt.qmodelindex_delete(index)

            switch err {
            case .Not_Exist:
                msg := fmt.aprintf("File \"%v\" specified in the body doesn't exist", request.body.binary_path)
                defer delete(msg)
                strings.write_string(&request.response.data, msg)
            case .Permission_Denied:
                msg := fmt.aprintf("Moonladder lacks the permissions to access \"%v\"", request.body.binary_path)
                defer delete(msg)
                strings.write_string(&request.response.data, msg)
            case:
                log.errorf("Failed to open \"%s\": %v", request.body.binary_path, err)
                strings.write_string(&request.response.data, "Unknown error")
            }

            // qt.qabstractitemmodel_dataChanged(cast(^qt.QAbstractItemModel)requests_list_model, index, index, raw_data(roles[:]), cast(i32)len(roles))
            return
        }

        fi, stat_err := os.stat(request.body.binary_path, context.allocator)
        if stat_err != nil {
            request.status = .Error

            log.errorf("Failed to stat file \"%s\": %v", request.body.binary_path, stat_err)

            // roles := [?]i32{
            //     cast(i32)RequestListRoles.Status,
            //     cast(i32)RequestListRoles.ResponseData,
            // }

            // parent := qt.qmodelindex_create()
            // defer qt.qmodelindex_delete(parent)
            // index := qt.qabstractlistmodel_index(requests_list_model, request_index, 0, parent)
            // defer qt.qmodelindex_delete(index)

            // qt.qabstractitemmodel_dataChanged(cast(^qt.QAbstractItemModel)requests_list_model, index, index, raw_data(roles[:]), cast(i32)len(roles))

            return
        }
        defer os.file_info_delete(fi, context.allocator)

        ensure(curl.easy_setopt(handle, .POST, 1) == .E_OK)
        // Tell curl we're doing an upload so that it puts the content-length header
        // We can't put that header by hand, libcurl strips it.
        ensure(curl.easy_setopt(handle, .UPLOAD, 1) == .E_OK)
        ensure(curl.easy_setopt(handle, .INFILESIZE_LARGE, fi.size) == .E_OK)
        ensure(curl.easy_setopt(handle, .READDATA, file) == .E_OK)
        ensure(curl.easy_setopt(handle, .READFUNCTION, proc "c" (ptr: [^]u8, size, nmemb: uint, userdata: rawptr) -> uint {
            context = runtime.default_context()
            file := cast(^os.File)userdata

            buf := make([]u8, nmemb * size)
            defer delete(buf)
            read, err := os.read(file, buf)

            mem.copy(ptr, raw_data(buf), read)

            return cast(uint)read
        }) == .E_OK)
    }

    final_url := build_final_request_url(request, effective_auth)
    defer delete(final_url)
    final_url_cstr := strings.clone_to_cstring(final_url)
    defer delete(final_url_cstr)

    // TODO: skip ssl verification option
    // ensure(curl.easy_setopt(handle, .SSL_VERIFYHOST, false) == .E_OK)
    // ensure(curl.easy_setopt(handle, .SSL_VERIFYPEER, false) == .E_OK)
    ensure(curl.easy_setopt(handle, .URL, final_url_cstr) == .E_OK)
    ensure(curl.easy_setopt(handle, .HTTPHEADER, request.curl_headers) == .E_OK)
    method := strings.to_upper(reflect.enum_string(request.method))
    defer delete(method)
    ensure(curl.easy_setopt(handle, .CUSTOMREQUEST, method) == .E_OK)
    ensure(curl.easy_setopt(handle, .FOLLOWLOCATION, state.config.follow_redirects) == .E_OK)
    ensure(curl.easy_setopt(handle, .WRITEFUNCTION, proc "c" (buffer: [^]byte, size, nitems: uint, userdata: rawptr) -> uint {
        context = runtime.default_context()
        sb := cast(^strings.Builder)userdata

        data := strings.string_from_ptr(buffer, cast(int)nitems)
        strings.write_string(sb, data)

        return nitems
    }) == .E_OK)
    ensure(curl.easy_setopt(handle, .WRITEDATA, &request.response.data) == .E_OK)
    curl.easy_setopt(handle, .HEADERDATA, &request.response.headers)
    curl.easy_setopt(handle, .HEADERFUNCTION, proc "c" (buffer: [^]byte, size, nitems: uint, userdata: rawptr) -> uint {
        context = runtime.default_context()

        headers := cast(^[dynamic]ResponseHeader)userdata
        data := strings.trim_space(strings.string_from_ptr(buffer, cast(int)(size * nitems)))
        if data == "" {
            return size * nitems
        }

        // If we received a new response, discard previous headers (e.g. redirects).
        if len(data) >= 5 && data[:5] == "HTTP/" {
            for header in headers {
                delete(header.key)
                delete(header.value)
            }
            clear(headers)
        }

        sep := strings.index_byte(data, ':')
        if sep <= 0 {
            return size * nitems
        }

        key_value := strings.split_n(data, ": ", 2)
        defer delete(key_value)

        if len(key_value) > 1 {
            key := strings.to_lower(key_value[0])
            value := strings.clone(key_value[1])
            header := ResponseHeader{key, value}

            // Allow duplicating these specific headers.
            // Set-Cookie: RFC9110 Section 5.3
            // WWW-Authenticate: https://developer.mozilla.org/en-US/docs/Web/HTTP/Reference/Headers/WWW-Authenticate
            if key != "set-cookie" && key != "www-authenticate" {
                for &existing_header in headers {
                    if existing_header.key == key {
                        delete(key)
                        delete(value)
                        merged := strings.join({existing_header.value, key_value[1]}, ", ")
                        delete(existing_header.value)
                        existing_header.value = merged
                        return size * nitems
                    }
                }
            }

            append(headers, header)
        }

        return size * nitems
    })
    ensure(curl.easy_setopt(handle, .TIMEOUT_MS, state.config.timeout_ms) == .E_OK)

    curl.multi_add_handle(state.curl_multi_handle, handle)
}

new_request_tab :: proc() {
    req := new(Request)
    req.id = rand.int63()
    req.active_options_tab = .Parameters
    req.name[0] = 'U'
    req.name[1] = 'n'
    req.name[2] = 't'
    req.name[3] = 'i'
    req.name[4] = 't'
    req.name[5] = 'l'
    req.name[6] = 'e'
    req.name[7] = 'd'
    req.headers = make([dynamic]RequestHeader)

    // Only init the text builder because the dyn arrays are inited on the first append
    req.body.text = strings.builder_make_len_cap(0, 1024)

    // NOTE: some sites return a 403 if we don't send a user-agent. Should probably also look into
    // adding some other default headers (check postman and hoppscotch)
    user_agent := RequestHeader{id = rand.int63()}
    copy(user_agent.key[:], "User-Agent")
    when RELEASE_BUILD {
        copy(user_agent.value[:], "moonladder" + "/" + VERSION)
    } else {
        copy(user_agent.value[:], "moonladder" + "/" + "debug")
    }

    accept := RequestHeader{id = rand.int63()}
    copy(accept.key[:], "Accept")
    copy(accept.value[:], "*/*")

    append(&req.headers, user_agent)
    append(&req.headers, accept)
    // TODO: requires that we set something in curl??
    // req.headers["Connection"] = "keep-alive"
    // TODO: requires that we can actually handle those compressions.
    // req.headers["Accept-Encoding"] = "gzip, deflate, br"

    // NOTE: make sure to always add whatever gets hashed BEFORE calculating and setting the hash.
    req.modification_hash = hash_request(req)

    append(&state.tabs, req)
}

hash_request :: proc(request: ^Request) -> u128 {
    // TODO: we no longer use imgui
    // Only hash the bytes up to the null terminator since imgui optimizes ctrl+backspace
    // by setting the first byte to a null terminator and the remaining bytes no longer equal zeros
    xxhash.XXH3_128_update(state.hasher, request.name[:len(cstring(&request.name[0]))])
    xxhash.XXH3_128_update(state.hasher, {cast(u8)request.method})
    xxhash.XXH3_128_update(state.hasher, request.url[:len(cstring(&request.url[0]))])
    for &param in request.query_params {
        xxhash.XXH3_128_update(state.hasher, param.key[:len(cstring(&param.key[0]))])
        xxhash.XXH3_128_update(state.hasher, {cast(u8)param.disabled})
        xxhash.XXH3_128_update(state.hasher, param.value[:len(cstring(&param.value[0]))])
    }

    for &header in request.headers {
        xxhash.XXH3_128_update(state.hasher, header.key[:len(cstring(&header.key[0]))])
        xxhash.XXH3_128_update(state.hasher, {cast(u8)header.disabled})
        xxhash.XXH3_128_update(state.hasher, header.value[:len(cstring(&header.value[0]))])
    }

    for key, &value in request.path_params {
        xxhash.XXH3_128_update(state.hasher, transmute([]u8)key)
        xxhash.XXH3_128_update(state.hasher, value.value[:len(cstring(&value.value[0]))])

        for index in value.indices {
            start := (transmute([8]u8)index.start)
            end := (transmute([8]u8)index.end)
            xxhash.XXH3_128_update(state.hasher, start[:])
            xxhash.XXH3_128_update(state.hasher, end[:])
        }
    }

    xxhash.XXH3_128_update(state.hasher, {cast(u8)request.auth.type})
    xxhash.XXH3_128_update(state.hasher, request.auth.basic_username[:len(cstring(&request.auth.basic_username[0]))])
    xxhash.XXH3_128_update(state.hasher, request.auth.basic_password[:len(cstring(&request.auth.basic_password[0]))])
    xxhash.XXH3_128_update(state.hasher, request.auth.bearer_token[:len(cstring(&request.auth.bearer_token[0]))])
    xxhash.XXH3_128_update(state.hasher, request.auth.bearer_prefix[:len(cstring(&request.auth.bearer_prefix[0]))])
    xxhash.XXH3_128_update(state.hasher, request.auth.api_key_key[:len(cstring(&request.auth.api_key_key[0]))])
    xxhash.XXH3_128_update(state.hasher, request.auth.api_key_value[:len(cstring(&request.auth.api_key_value[0]))])
    xxhash.XXH3_128_update(state.hasher, {cast(u8)request.auth.api_key_add_to})

    xxhash.XXH3_128_update(state.hasher, {cast(u8)request.body.type})

    if strings.builder_len(request.body.text) > 0 {
        xxhash.XXH3_128_update(state.hasher, request.body.text.buf[:])
    }
    for &field in request.body.structured {
        xxhash.XXH3_128_update(state.hasher, field.key[:])
        xxhash.XXH3_128_update(state.hasher, {cast(u8)field.disabled})
        xxhash.XXH3_128_update(state.hasher, {cast(u8)field.is_file})
        xxhash.XXH3_128_update(state.hasher, field.value[:])
        for file_path in field.file_paths {
            xxhash.XXH3_128_update(state.hasher, transmute([]u8)file_path)
        }
        xxhash.XXH3_128_update(state.hasher, field.content_type[:])
    }
    xxhash.XXH3_128_update(state.hasher, transmute([]u8)request.body.binary_path)

    defer xxhash.XXH3_128_reset(state.hasher)

    return xxhash.XXH3_128_digest(state.hasher)
}

modify_request :: proc(request: ^Request) {
    request.is_modified = hash_request(request) != request.modification_hash
}

main :: proc() {
    console_logger := log.create_console_logger()
    defer log.destroy_console_logger(console_logger)
    log_file, log_file_err := os.open("moonladder.log", {.Write, .Trunc, .Create}, os.Permissions_Read_All + {.Write_User})
    if log_file_err != nil {
        fmt.println("[ERROR] Failed to open log file:", log_file_err)
        return
    }
    defer os.close(log_file)
    file_logger := log.create_file_logger(log_file)
    defer log.destroy_file_logger(file_logger)
    logger = log.create_multi_logger(console_logger, file_logger)
    context.logger = logger
    defer log.destroy_console_logger(context.logger)

    config_dir, config_dir_err := os.user_config_dir(context.allocator)
    if config_dir_err != nil {
        log.error("Failed to get user's config directory:", config_dir_err)
        return
    }
    defer delete(config_dir)

    when RELEASE_BUILD {
        sentry_config_path_str, _ := os.join_path({config_dir, CONFIG_DIR, ".sentry-native"}, context.allocator)
        sentry_config_path := strings.clone_to_cstring(sentry_config_path_str)
        defer delete(sentry_config_path)

        sentry_opts := sentry.options_new()
        sentry.options_set_dsn(sentry_opts, SENTRY_DSN)
        sentry.options_set_database_path(sentry_opts, sentry_config_path)
        sentry.options_set_environment(sentry_opts, "production")
        sentry.options_set_release(sentry_opts, VERSION)
        sentry.options_set_debug(sentry_opts, false)
        ensure(sentry.init(sentry_opts) == 0)
        defer sentry.close()
    }

    state.hasher = xxhash.XXH3_create_state() or_else panic("Failed to create hasher")
    defer xxhash.XXH3_destroy_state(state.hasher)

    defer cleanup()

    marshallers := new(map[typeid]json.User_Marshaler)
    defer free(marshallers)
    defer delete(marshallers^)

    unmarshallers := new(map[typeid]json.User_Unmarshaler)
    defer free(unmarshallers)
    defer delete(unmarshallers^)

    json.set_user_marshalers(marshallers)
    json.register_user_marshaler(Workspace, workspace_marshaller)
    json.register_user_marshaler(^Collection, collection_marshaller)
    json.register_user_marshaler(Environment, environment_marshaller)
    json.register_user_marshaler(EnvironmentVariableField, environment_variable_field_marshaller)
    json.register_user_marshaler(Request, request_marshaller)
    json.register_user_marshaler(RequestHeader, key_value_marshaller)
    json.register_user_marshaler(QueryParam, key_value_marshaller)
    json.register_user_marshaler(FormField, form_field_marshaller)
    json.register_user_marshaler(PathParam, path_param_marshaller)

    json.set_user_unmarshalers(unmarshallers)
    json.register_user_unmarshaler(^Collection, collection_unmarshaller)
    json.register_user_unmarshaler(Workspace, workspace_unmarshaller)

    load_config_and_initialize_state()

    log.assert(len(state.workspaces) > 0)

    title := fmt.caprintf("Moonladder %s-%s", VERSION if VERSION != "" else "debug", GIT_SHA)
    engine.init("", title, {1000, 600}, false)
    ensure(engine.ui_text_register_font("res/fonts/RedHatDisplay.ttf"))
    ensure(engine.ui_text_register_font("res/fonts/icons.ttf"))
    ensure(engine.ui_text_register_font("/usr/share/fonts/truetype/Tajawal/Tajawal-Regular.ttf"))
    // assert(engine.ui_text_register_font("res/fonts/NotoSansCJK-Regular.ttc"))
    // assert(engine.ui_text_register_font("res/fonts/NotoSansEgyptianHieroglyphs-Regular.ttf"))
    // assert(engine.ui_text_register_font("res/fonts/NotoColorEmoji.ttf"))
    engine.set_clear_color(engine.color_hex_rgb(THEME_BACKGROUND_SECONDARY_DEFAULT[state.config.theme]))
    engine.set_msaa(.NONE)
    engine.set_render_on_change(true)

    logo = engine.load_texture(#load("./res/icons/moonladder.png"), false, true)

    ensure(curl.global_init(curl.GLOBAL_DEFAULT) == .E_OK)
    defer curl.global_cleanup()
    state.curl_multi_handle = curl.multi_init()
    defer curl.multi_cleanup(state.curl_multi_handle)

    polling_thread := thread.create_and_start(curl_poll_thread)
    defer thread.destroy(polling_thread)
    defer thread.terminate(polling_thread, 0)

    for !engine.should_quit() {
        engine.frame_start()

        e := engine.iter_events()
        for e != nil {
            #partial switch e.type {
            case .WINDOW_CLOSED:
                engine.quit()
            case .VIRT_KEY_PRESSED:
                if e.key.scancode == .F3 {
                    state.show_ui_debug_overlay = !state.show_ui_debug_overlay
                }
                if e.key.scancode == .T {
                    if .LEFT_CTRL in e.key.mods || .RIGHT_CTRL in e.key.mods {
                        new_request_tab()
                        state.active_tab_index = len(state.tabs) - 1
                    } else {
                        // state.config.theme = state.config.theme == .Light ? .Dark : .Light
                        // engine.set_clear_color(engine.color_hex_rgb(THEME_BACKGROUND_SECONDARY_DEFAULT[state.config.theme]))
                        // save_config()
                    }
                }
                if e.key.scancode == .W {
                    if .LEFT_CTRL in e.key.mods || .RIGHT_CTRL in e.key.mods {
                        if len(state.tabs) > 0 {
                            ordered_remove(&state.tabs, state.active_tab_index)
                            if state.active_tab_index >= len(state.tabs) {
                                state.active_tab_index = len(state.tabs) - 1
                            }
                        }
                    }
                }
            }

            e = engine.iter_events()
        }

        if engine.should_render_frame() {
            window_size := engine.get_window_size()

            engine.ui_begin_build(window_size)
            engine.ui_text_set_default_pixel_size(16)
            engine.ui_text_set_default_font_weight(THEME_FONT_WEIGHT_BODY)
            {
                engine.ui_set_next_width(engine.ui_fill())
                engine.ui_set_next_height(engine.ui_fill())
                engine.ui_set_next_background_color(engine.color_hex_rgb(THEME_BACKGROUND_PRIMARY_DEFAULT[state.config.theme]))
                engine.ui_set_next_flags({.DrawBackground})
                engine.ui_column(); {
                    engine.ui_push_text_color(engine.color_hex_rgb(THEME_TEXT_PRIMARY_DEFAULT[state.config.theme]))
                    defer engine.ui_pop_text_color()

                    draw_topbar()
                    BORDER_H()
                    engine.ui_set_next_width(engine.ui_fill())
                    engine.ui_set_next_height(engine.ui_fill())
                    engine.ui_row(); {
                        draw_sidebar()
                        split_interactive, split_visual := engine.ui_split_divider(.Y, &state.config.sidebar_width, 350, 600, hit_thickness = 7)
                        sig := engine.ui_signal_from_box(split_interactive)
                        if engine.ui_hovering(sig) || engine.ui_dragging(sig) {
                            split_visual.background_color = engine.color_hex_rgb(THEME_BORDER_BRAND_DEFAULT)
                        } else {
                            split_visual.background_color = engine.color_hex_rgb(THEME_BORDER_PRIMARY_DEFAULT[state.config.theme])
                        }
                        draw_main_area()
                    }

                }
            }
            draw_ui_debug_overlay()
            engine.ui_end_build()

            engine.ui_draw(engine.get_projection())
        }

        engine.frame_end()
    }

    // Save config to preserve any changes to the window size or sidebar width
    save_config()

    engine.deinit()
}

curl_poll_thread :: proc() {
    context.logger = logger

    for {
        still_running: i32
        res := curl.multi_perform(state.curl_multi_handle, &still_running)
        if res != .OK {
            log.error("curl_multi_perform failed with:", res)
            continue
        }

        res = curl.multi_poll(state.curl_multi_handle, nil, 0, 10, nil)
        if res != .OK {
            log.error("curl_multi_wait failed with:", res)
            continue
        }

        msgs_left: i32
        for {
            msg := curl.multi_info_read(state.curl_multi_handle, &msgs_left)
            if msg == nil {
                break
            }

            if msg.msg == .DONE {
                handle := msg.easy_handle

                for &tab in state.tabs {
                    req, is_request := tab.(^Request)
                    if !is_request { continue }
                    if req.curl_handle == handle {
                        curl.slist_free_all(req.curl_headers)
                        req.curl_headers = nil
                        if req.form != nil {
                            curl.mime_free(req.form)
                            req.form = nil
                        }

                        assert(curl.easy_getinfo(handle, .TOTAL_TIME_T, &req.response.time.total) == .E_OK)
                        assert(curl.easy_getinfo(handle, .SIZE_DOWNLOAD_T, &req.response.size) == .E_OK)

                        #partial switch msg.data.result {
                        case .E_OK:
                            req.status = .Success

                            assert(curl.easy_getinfo(handle, .RESPONSE_CODE, &req.response.status_code) == .E_OK)
                            response_body := strings.to_string(req.response.data)
                            normalized_body := response_body
                            did_normalize := false
                            req.response.has_escaped_unicode = false
                            req.response.show_escaped_unicode = false

                            // if decoded_body, changed := normalize_response_body(req.response.headers[:], response_body); changed {
                            //     normalized_body = decoded_body
                            //     did_normalize = true
                            //     req.response.has_escaped_unicode = true
                            //     strings.builder_reset(&req.response.raw_data)
                            //     strings.write_string(&req.response.raw_data, response_body)
                            //     strings.builder_reset(&req.response.data)
                            //     strings.write_string(&req.response.data, normalized_body)
                            // } else {
                            //     strings.builder_reset(&req.response.raw_data)
                            //     strings.builder_reset(&req.response.raw_pretty_data)
                            // }

                            defer if did_normalize {
                                delete(normalized_body)
                            }

                            // pretty_format := detect_response_pretty_format(req.response.headers[:])
                            // prettify_response(normalized_body, pretty_format, &req.response.pretty_data)
                            // if req.response.has_escaped_unicode {
                            //     prettify_response(response_body, pretty_format, &req.response.raw_pretty_data)
                            // }
                        case .E_GOT_NOTHING:
                            req.status = .Error
                            strings.write_string(&req.response.data, "Nothing was received")
                        case .E_COULDNT_RESOLVE_HOST:
                            req.status = .Error
                            strings.write_string(&req.response.data, "Could not resolve host")
                        case .E_OPERATION_TIMEDOUT:
                            req.status = .Error
                            strings.write_string(&req.response.data, "Request timed out")
                        case .E_COULDNT_CONNECT:
                            req.status = .Error
                            strings.write_string(&req.response.data, "Could not connect to host")
                        case .E_URL_MALFORMAT:
                            req.status = .Error
                            strings.write_string(&req.response.data, "URL is not properly formatted")
                        case .E_PEER_FAILED_VERIFICATION:
                            req.status = .Error
                            // TODO: CA stores are not implemented yet
                            strings.write_string(&req.response.data, "Failed to verify the SSL certificate. To ignore this warning and force a response, toggle the \"Skip certificate verification\" option in settings.\nOr alternatively, set up a CA store if this is a self-signed certificate.")
                        case:
                            req.status = .Error
                            strings.write_string(&req.response.data, "An unknown error occurred.")
                            // TODO: handle results other than E_OK
                            log.debug("Request finished with unhandled non OK result. Result:", msg.data.result)
                        }

                        // if global_q_obj != nil {
                        //     dispatch_data := new(RequestCompletionUiDispatch)
                        //     dispatch_data.request_id = req.id

                        //     if !qt.qmetaobject_invoke_method(global_q_obj, dispatch_request_completion_to_ui, dispatch_data, .QueuedConnection) {
                        //         free(dispatch_data)
                        //         log.error("Failed to dispatch request completion to UI thread")
                        //     }
                        // }

                        req.curl_handle = nil
                        break
                    }
                }

                curl.multi_remove_handle(state.curl_multi_handle, handle)
                curl.easy_cleanup(handle)
            }
        }
    }
}
