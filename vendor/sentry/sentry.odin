package sentry

when ODIN_OS == .Linux {
foreign import sentry {
	"lib/linux/libsentry.a",
	"lib/linux/libcrashpad_client.a",
	"lib/linux/libcrashpad_util.a",
	"lib/linux/libmini_chromium.a",
	"lib/linux/libcrashpad_mpack.a",
	"lib/linux/libunwind.a",
}
} else when ODIN_OS == .Windows {
@(extra_linker_flags="/NODEFAULTLIB:libcmt")
foreign import sentry {
	"lib/windows/sentry.lib",
	"lib/windows/crashpad_client.lib",
	"lib/windows/crashpad_util.lib",
	"lib/windows/mini_chromium.lib",
	"lib/windows/crashpad_mpack.lib",
	"system:winhttp.lib",
	"system:version.lib",
	"system:Synchronization.lib",
	"system:Dbghelp.lib",
	"system:msvcrt.lib",
}
} else when ODIN_OS == .Darwin && (ODIN_ARCH == .amd64 || ODIN_ARCH == .arm64) {
foreign import sentry { // These are "fat" libraries that contain both x86_64 and arm64 code
	"lib/macos/libsentry.a",
	"lib/macos/libcrashpad_client.a",
	"lib/macos/libcrashpad_util.a",
	"lib/macos/libmini_chromium.a",
	"lib/macos/libcrashpad_mpack.a",
	"system:CoreFoundation.framework",
	"system:CoreGraphics.framework",
	"system:CoreText.framework",
	"system:Foundation.framework",
	"system:IOKit.framework",
}
} else {
	#panic("Unsupported platform")
}

/// Represents a sentry protocol value.
///
/// Values must be released with `sentry_value_decref`.
sentry_value_t :: distinct u64

/// Sentry levels for events and breadcrumbs.
sentry_level_t :: enum i32 {
	TRACE   = -2,
	DEBUG   = -1,
	INFO    = 0,
	WARNING = 1,
	ERROR   = 2,
	FATAL   = 3,
}

/// A UUID.
sentry_uuid_t :: struct {
	bytes: [16]u8,
}

/// The Sentry Client Options.
///
/// See https://docs.sentry.io/platforms/native/configuration/
sentry_options_t :: struct {}

@(link_prefix="sentry_")
foreign sentry {
	/// Creates a new options struct.
	/// Can be freed with `sentry_options_free`.
	options_new            :: proc() -> ^sentry_options_t ---

	/// Sets the DSN.
	options_set_dsn        :: proc(opts: ^sentry_options_t, dsn: cstring) ---

	/// Sets the path to the Sentry Database Directory.
	///
	/// If no explicit path is set, sentry-native defaults to `.sentry-native`
	/// in the current working directory.
	options_set_database_path :: proc(opts: ^sentry_options_t, path: cstring) ---

	//
	// Sets the release.
	//
	options_set_release :: proc(opts: ^sentry_options_t, release: cstring) ---

	//
	// Sets the environment.
	//
	options_set_environment :: proc(opts: ^sentry_options_t, environment: cstring) ---
	options_set_environment_n :: proc(opts: ^sentry_options_t, environment: cstring, environment_len: uint) ---

	//
	// Enables or disables debug printing mode. To change the log level from the
	// default DEBUG level, use `sentry_options_set_logger_level`.
	//
	options_set_debug :: proc(opts: ^sentry_options_t, debug: b32) ---


	/// Initializes the Sentry SDK with the specified options.
	///
	/// This takes ownership of the options.
	/// Returns 0 on success.
	init  :: proc(options: ^sentry_options_t) -> i32 ---

	/// Instructs the transport to flush its send-queue.
	///
	/// `timeout_ms` is in milliseconds.
	/// Returns 0 on success.
	flush :: proc(timeout_ms: u64) -> i32 ---

	/// Shuts down the sentry client and forces transports to flush out.
	///
	/// Returns the number of envelopes that have been dumped.
	close :: proc() -> i32 ---

	/// Creates a new Message Event value.
	///
	/// `logger` can be nil to omit the logger value.
	value_new_message_event :: proc(level: sentry_level_t, logger: cstring, text: cstring) -> sentry_value_t ---

	/// Sends a sentry event.
	///
	/// Returns a nil UUID if sending fails.
	capture_event           :: proc(event: sentry_value_t) -> sentry_uuid_t ---

	/// Checks if the UUID is nil.
	uuid_is_nil :: proc(uuid: ^sentry_uuid_t) -> i32 ---

	/// Formats the into a string buffer.
	uuid_as_string :: proc(uuid: ^sentry_uuid_t, str: ^[37]u8) ---
}
