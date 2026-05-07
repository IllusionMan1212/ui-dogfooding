package main

Theme :: enum {
    Light,
    Dark,
}

THEME_BACKGROUND_PRIMARY_DEFAULT := [Theme]u32{
    .Light = 0xFFFFFF,
    .Dark = 0x071327,
}

THEME_BACKGROUND_SECONDARY_DEFAULT := [Theme]u32{
    .Light = 0xF5F5F5,
    .Dark = 0x172135,
}

THEME_BORDER_PRIMARY_DEFAULT := [Theme]u32{
    .Light = 0xD5D7DA,
    .Dark = 0x2C374E,
}

THEME_TEXT_PRIMARY_DEFAULT := [Theme]u32{
    .Light = 0x050609,
    .Dark = 0xFFFFFF,
}
