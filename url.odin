package main

import "core:strings"

is_url_hex_digit :: #force_inline proc "contextless" (b: u8) -> bool {
    return (b >= '0' && b <= '9') || (b >= 'a' && b <= 'f') || (b >= 'A' && b <= 'F')
}

is_url_path_char :: #force_inline proc "contextless" (b: u8) -> bool {
    switch b {
    case 'a'..='z', 'A'..='Z', '0'..='9': return true
    case '-', '.', '_', '~': return true
    case '$', '&', '+', ':', '=', '@': return true
    }
    return false
}

is_url_unreserved_char :: #force_inline proc "contextless" (b: u8) -> bool {
    return (b >= 'a' && b <= 'z') ||
           (b >= 'A' && b <= 'Z') ||
           (b >= '0' && b <= '9') ||
           b == '-' || b == '.' || b == '_' || b == '~'
}

// RFC3986 percent-encoding for a single query parameter component (key or value).
// This preserves already-encoded %XX triplets to avoid double-encoding.
percent_encode_query_param_component :: proc(component: string, allocator := context.allocator) -> string {
    sb := strings.builder_make_len_cap(0, len(component) + 16, allocator)
    hex_chars := "0123456789ABCDEF"

    for i := 0; i < len(component); {
        b := component[i]
        if b == '%' && i + 2 < len(component) && is_url_hex_digit(component[i+1]) && is_url_hex_digit(component[i+2]) {
            strings.write_byte(&sb, '%')
            strings.write_byte(&sb, component[i+1])
            strings.write_byte(&sb, component[i+2])
            i += 3
        } else if is_url_unreserved_char(b) {
            strings.write_byte(&sb, b)
            i += 1
        } else {
            strings.write_byte(&sb, '%')
            strings.write_byte(&sb, hex_chars[b >> 4])
            strings.write_byte(&sb, hex_chars[b & 0xf])
            i += 1
        }
    }

    return strings.to_string(sb)
}

// Percent-encodes a single URL path segment.
// This follows Go's PathEscape compatibility behavior and preserves existing %XX triplets.
percent_encode_url_path :: proc(path: string, allocator := context.allocator) -> string {
    sb := strings.builder_make_len_cap(0, len(path) + 32, allocator)
    hex_chars := "0123456789ABCDEF"
    for i := 0; i < len(path); {
        b := path[i]
        if b == '%' && i + 2 < len(path) && is_url_hex_digit(path[i+1]) && is_url_hex_digit(path[i+2]) {
            strings.write_byte(&sb, '%')
            strings.write_byte(&sb, path[i+1])
            strings.write_byte(&sb, path[i+2])
            i += 3
        } else if is_url_path_char(b) {
            strings.write_byte(&sb, b)
            i += 1
        } else {
            strings.write_byte(&sb, '%')
            strings.write_byte(&sb, hex_chars[b >> 4])
            strings.write_byte(&sb, hex_chars[b & 0xf])
            i += 1
        }
    }

    return strings.to_string(sb)
}

// Percent-encodes a full URL path while preserving '/' separators.
percent_encode_url_path_preserving_slashes :: proc(path: string, allocator := context.allocator) -> string {
    sb := strings.builder_make_len_cap(0, len(path) + 32, allocator)

    segment_start := 0
    for i := 0; i <= len(path); i += 1 {
        if i < len(path) && path[i] != '/' {
            continue
        }

        segment := path[segment_start:i]
        encoded_segment := percent_encode_url_path(segment, allocator)
        strings.write_string(&sb, encoded_segment)
        delete(encoded_segment)

        if i < len(path) {
            strings.write_byte(&sb, '/')
        }

        segment_start = i + 1
    }

    return strings.to_string(sb)
}

