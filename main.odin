package main

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

import "vendor:curl"

import "engine"

import "vendor/sentry"

RELEASE_BUILD :: #config(RELEASE_BUILD, false)
VERSION :: #config(VERSION, "")
GIT_SHA :: #config(GIT_SHA, "debug")

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

http_method_string :: proc(m: HttpMethod) -> string #no_bounds_check {
	if m < .Get || m > .Trace { return "" }
	return http_method_strings[m]
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

    // Qt-specific
    // query_params_model: ^qt.QAbstractTableModel `json:"-"`, // 8
    // headers_model: ^qt.QAbstractTableModel `json:"-"`, // 8
    // path_params_model: ^qt.QAbstractTableModel `json:"-"`, // 8
    // response_headers_model: ^qt.QAbstractTableModel `json:"-"`, // 8
    // body_form_model: ^qt.QAbstractTableModel `json:"-"`, // 8

    // Ephemeral UI state for this open request tab.
    active_options_tab: RequestOptionsTab `json:"-"`, // 8
    active_response_tab: RequestResponseTab `json:"-"`, // 8
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
    theme: Theme `json:"theme"`,
    timeout_ms: int `json:"timeout_ms"`,
    follow_redirects: bool `json:"follow_redirects"`,
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
    active_sidebar_tab: SidebarTab,
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

SCROLLBAR_V :: proc(scrollable: proc() -> ^engine.Box) {
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
    engine.ui_set_next_height(engine.ui_px(64, 1))
    engine.ui_set_next_background_color(engine.color_hex_rgb(THEME_BACKGROUND_SECONDARY_DEFAULT[state.config.theme]))
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
        if draw_icon_button(.Settings, engine.color_hex_rgb(THEME_ICON_SECONDARY_DEFAULT[state.config.theme]), size = .ExtraSmall, variant = .SecondaryGrey) {
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
            0x00,
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
            0x00,
            engine.color_hex_rgb(THEME_BACKGROUND_SECONDARY_DEFAULT[state.config.theme]),
            0x00,
            0x00,
            0x00,
            engine.color_hex_rgb(THEME_TEXT_TERTIARY_DEFAULT[state.config.theme]),
            engine.color_hex_rgb(THEME_TEXT_SECONDARY_DEFAULT[state.config.theme]),
            engine.color_hex_rgb(THEME_TEXT_PRIMARY_DISABLED[state.config.theme]),
        },
        .TertiaryColored = {
            0x00,
            engine.color_hex_rgb(THEME_BACKGROUND_PRIMARY_DEFAULT_HOVER[state.config.theme]),
            0x00,
            0x00,
            0x00,
            engine.color_hex_rgb(THEME_TEXT_BRAND_DEFAULT[state.config.theme]),
            engine.color_hex_rgb(THEME_TEXT_BRAND_DEFAULT[state.config.theme]),
            engine.color_hex_rgb(THEME_TEXT_PRIMARY_DISABLED[state.config.theme]),
        },
        .LinkGrey = {
            0x00,
            0x00,
            0x00,
            0x00,
            0x00,
            engine.color_hex_rgb(THEME_TEXT_SECONDARY_DEFAULT[state.config.theme]),
            engine.color_hex_rgb(THEME_TEXT_SECONDARY_HOVER[state.config.theme]),
            engine.color_hex_rgb(THEME_TEXT_PRIMARY_DISABLED[state.config.theme]),
        },
        .LinkColored = {
            0x00,
            0x00,
            0x00,
            0x00,
            0x00,
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
            engine.color_hex_rgb(THEME_BACKGROUND_BRAND_SOLID_HOVER[state.config.theme]),
            engine.color_hex_rgb(THEME_BACKGROUND_PRIMARY_DISABLED[state.config.theme]),
            0x00,
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
            0x00,
            engine.color_hex_rgb(THEME_BACKGROUND_SECONDARY_DEFAULT[state.config.theme]),
            0x00,
            0x00,
            0x00,
            engine.color_hex_rgb(THEME_TEXT_TERTIARY_DEFAULT[state.config.theme]),
            engine.color_hex_rgb(THEME_TEXT_SECONDARY_DEFAULT[state.config.theme]),
            engine.color_hex_rgb(THEME_TEXT_PRIMARY_DISABLED[state.config.theme]),
        },
        .TertiaryColored = {
            0x00,
            engine.color_hex_rgb(THEME_BACKGROUND_PRIMARY_DEFAULT_HOVER[state.config.theme]),
            0x00,
            0x00,
            0x00,
            engine.color_hex_rgb(THEME_TEXT_BRAND_DEFAULT[state.config.theme]),
            engine.color_hex_rgb(THEME_TEXT_BRAND_DEFAULT[state.config.theme]),
            engine.color_hex_rgb(THEME_TEXT_PRIMARY_DISABLED[state.config.theme]),
        },
        .LinkGrey = {
            0x00,
            0x00,
            0x00,
            0x00,
            0x00,
            engine.color_hex_rgb(THEME_TEXT_SECONDARY_DEFAULT[state.config.theme]),
            engine.color_hex_rgb(THEME_TEXT_SECONDARY_HOVER[state.config.theme]),
            engine.color_hex_rgb(THEME_TEXT_PRIMARY_DISABLED[state.config.theme]),
        },
        .LinkColored = {
            0x00,
            0x00,
            0x00,
            0x00,
            0x00,
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
    return engine.ui_button_styled(ICONS[icon], style, enabled = enabled)
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

            engine.ui_set_next_width(engine.ui_px(6, 1))
            engine.ui_set_next_height(engine.ui_fill())
            scrollbar := engine.ui_scrollbar_y_for(scroll_box)
            scrollbar.background_color = {0,0,0,0}
            scrollbar.border_color = engine.color_hex_rgb(THEME_BORDER_PRIMARY_DEFAULT[state.config.theme])
            scrollbar.border_radius = THEME_BORDER_RADIUS_MD

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
        box := engine.ui_row(engine.Id(collection.id)); sig := engine.ui_signal_from_box(box); {
            if engine.ui_hovering(sig) {
                box.background_color = engine.color_hex_rgb(THEME_BACKGROUND_SECONDARY_DEFAULT_HOVER[state.config.theme])
            } else {
                box.background_color = 0x00
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

                engine.ui_set_next_text_color(engine.color_hex_rgb(THEME_TEXT_SECONDARY_DEFAULT[state.config.theme]))
                // TODO: should return signal or box so we can use it for hover and click
                engine.ui_text_sized(ICONS[.Plus], 12)

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
        for child := collection.first; child != nil; child = child.next {
            draw_collection_item(child, indent_level + 1)
        }
        for &request in collection.requests {
            draw_request_item(&request, indent_level + 1)
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
    box := engine.ui_row(engine.Id(request.id)); sig := engine.ui_signal_from_box(box); {
        if engine.ui_hovering(sig) {
            box.background_color = engine.color_hex_rgb(THEME_BACKGROUND_SECONDARY_DEFAULT_HOVER[state.config.theme])
        } else {
            box.background_color = 0x00
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
    box := engine.ui_row(engine.Id(environment.id)); {
        sig := engine.ui_signal_from_box(box)
        if engine.ui_hovering(sig) {
            box.background_color = engine.color_hex_rgb(THEME_BACKGROUND_SECONDARY_DEFAULT_HOVER[state.config.theme])
        } else {
            box.background_color = 0x00
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
    engine.ui_set_next_width(engine.ui_px(350, 1))
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

                if draw_icon_button(.Folder, engine.color_hex_rgb(state.active_sidebar_tab == .Collections ? THEME_BACKGROUND_PRIMARY_DEFAULT[state.config.theme] : THEME_ICON_SECONDARY_DEFAULT[state.config.theme]), size = .Small, variant = state.active_sidebar_tab == .Collections ? .Primary : .SecondaryGrey) {
                    state.active_sidebar_tab = .Collections
                }
                engine.ui_spacer(engine.ui_px(10, 1))
                if draw_icon_button(.Environment, engine.color_hex_rgb(state.active_sidebar_tab == .Environments ? THEME_BACKGROUND_PRIMARY_DEFAULT[state.config.theme] : THEME_ICON_SECONDARY_DEFAULT[state.config.theme]), size = .Small, variant = state.active_sidebar_tab == .Environments ? .Primary : .SecondaryGrey) {
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

draw_tab_item_request :: proc(req: ^Request, index: int) {
    engine.ui_set_next_width(engine.ui_children_sum(1))
    engine.ui_set_next_height(engine.ui_fill())
    engine.ui_set_next_align_y(.Center)
    engine.ui_set_next_flags({.MouseClickable, .DrawBackground})
    tab_box := engine.ui_column(engine.Id(req.id)); {
        tab_sig := engine.ui_signal_from_box(tab_box)
        tab_hovered := engine.ui_hovering(tab_sig)

        if state.active_tab_index == index {
            tab_box.background_color = engine.color_hex_rgb(THEME_BACKGROUND_SECONDARY_DEFAULT[state.config.theme])
        } else {
            tab_box.background_color = 0x00
        }

        if engine.ui_clicked(tab_sig) {
            state.active_tab_index = index
        }

        {
            engine.ui_set_next_width(engine.ui_children_sum(1))
            engine.ui_set_next_height(engine.ui_fill())
            engine.ui_set_next_align_y(.Center)
            engine.ui_row(); {
                engine.ui_padding(12, {.Left, .Right})

                name := string(cstring(&req.name[0]))

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

                        engine.ui_set_next_font_size(THEME_FONT_SIZE_BODY_SM)
                        engine.ui_set_next_text_color(engine.color_hex_rgb(tab_hovered || state.active_tab_index == index ? THEME_TEXT_PRIMARY_DEFAULT[state.config.theme] : THEME_TEXT_SECONDARY_DEFAULT[state.config.theme]))
                        engine.ui_text(name)
                    }
                }

                engine.ui_spacer(engine.ui_px(THEME_SPACING_MD, 1))

                if tab_hovered {
                    engine.ui_text(ICONS[.Close])
                } else {
                    engine.ui_spacer(engine.ui_px(16, 1))
                }
            }
        }

        // TODO: The border doesn't work because ui_fill just fills the entire tab bar, and ui_children_sum gives it 0 width
        // I need a way to either get the width of the tab item, or be able to draw separate border sides.
        {
            engine.ui_set_next_width(engine.ui_children_sum(1))
            engine.ui_set_next_height(engine.ui_px(1, 1))
            engine.ui_set_next_background_color(engine.color_hex_rgb(state.active_tab_index == index ? THEME_BORDER_BRAND_DEFAULT : 0x00))
            engine.ui_set_next_flags({.DrawBackground})
            engine.ui_row()
        }
    }
}

draw_tab_bar :: proc() {
    engine.ui_set_next_width(engine.ui_fill())
    engine.ui_set_next_height(engine.ui_px(40, 1))
    engine.ui_set_next_align_y(.Center)
    engine.ui_row(); {
        {
            engine.ui_set_next_width(engine.ui_children_sum(1))
            engine.ui_set_next_height(engine.ui_children_sum(1))
            engine.ui_row(); {
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
        if draw_icon_button(.Plus, engine.color_hex_rgb(THEME_ICON_SECONDARY_DEFAULT[state.config.theme]), 16, .TertiaryGrey, .Small) {
            new_request_tab()
            state.active_tab_index = len(state.tabs) - 1
        }

        engine.ui_spacer(engine.ui_fill())

        engine.ui_spacer(engine.ui_px(4, 1))
        {
            engine.ui_set_next_width(engine.ui_px(1, 1))
            engine.ui_set_next_height(engine.ui_fill())
            engine.ui_set_next_background_color(engine.color_hex_rgb(THEME_BORDER_PRIMARY_DEFAULT[state.config.theme]))
            engine.ui_set_next_flags({.DrawBackground})
            engine.ui_row()
        }

        if draw_button("No Environment", .TertiaryGrey, left_icon = .Environment, right_icon = .Chevron) {
            // TODO: open environment popup
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
            engine.ui_set_next_width(engine.ui_fill())
            engine.ui_set_next_height(engine.ui_fill())
            engine.ui_set_next_align_y(.Center)
            engine.ui_set_next_align_x(.Center)
            engine.ui_row(); {
                engine.ui_text_sized("Main Area", 64)
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
    overlay := engine.ui_column(engine.Id(0x0D00B6A1)); {
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

    // req.query_params_model = qt.qabstracttablemodel_create(req, table_qmeta, static_slot_callback, &query_params_model_callbacks)
    // req.headers_model = qt.qabstracttablemodel_create(req, table_qmeta, static_slot_callback, &headers_model_callbacks)
    // req.path_params_model = qt.qabstracttablemodel_create(req, table_qmeta, static_slot_callback, &path_params_model_callbacks)
    // req.response_headers_model = qt.qabstracttablemodel_create(req, table_qmeta, static_slot_callback, &response_headers_model_callbacks)
    // req.body_form_model = qt.qabstracttablemodel_create(req, table_qmeta, static_slot_callback, &form_fields_model_callbacks)
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
    engine.ui_text_set_default_pixel_size(20)
    engine.set_clear_color(engine.color_hex_rgb(THEME_BACKGROUND_SECONDARY_DEFAULT[state.config.theme]))
    engine.set_msaa(.NONE)

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
                    state.config.theme = state.config.theme == .Light ? .Dark : .Light
                    engine.set_clear_color(engine.color_hex_rgb(THEME_BACKGROUND_SECONDARY_DEFAULT[state.config.theme]))
                    save_config()
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
                    BORDER_V()
                    draw_main_area()
                }

            }
        }
        draw_ui_debug_overlay()
        engine.ui_end_build()

        engine.ui_draw(engine.get_projection())

        engine.frame_end()
    }
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
