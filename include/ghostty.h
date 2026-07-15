// Ghostty embedding API. The documentation for the embedding API is
// only within the Zig source files that define the implementations. This
// isn't meant to be a general purpose embedding API (yet) so there hasn't
// been documentation or example work beyond that.
//
// The only consumer of this API is the macOS app, but the API is built to
// be more general purpose.
#ifndef GHOSTTY_H
#define GHOSTTY_H

#ifdef __cplusplus
extern "C" {
#endif

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef _MSC_VER
#include <BaseTsd.h>
typedef SSIZE_T ssize_t;
#else
#include <sys/types.h>
#endif

//-------------------------------------------------------------------
// Macros

#define GHOSTTY_SUCCESS 0

// Symbol visibility for shared library builds. On Windows, functions
// are exported from the DLL when building and imported when consuming.
// On other platforms with GCC/Clang, functions are marked with default
// visibility so they remain accessible when the library is built with
// -fvisibility=hidden. For static library builds, define GHOSTTY_STATIC
// before including this header to make this a no-op.
#ifndef GHOSTTY_API
#if defined(GHOSTTY_STATIC)
  #define GHOSTTY_API
#elif defined(_WIN32) || defined(_WIN64)
  #ifdef GHOSTTY_BUILD_SHARED
    #define GHOSTTY_API __declspec(dllexport)
  #else
    #define GHOSTTY_API __declspec(dllimport)
  #endif
#elif defined(__GNUC__) && __GNUC__ >= 4
  #define GHOSTTY_API __attribute__((visibility("default")))
#else
  #define GHOSTTY_API
#endif
#endif

//-------------------------------------------------------------------
// Types

// Opaque types
typedef void* ghostty_app_t;
typedef void* ghostty_config_t;
typedef void* ghostty_surface_t;
typedef void* ghostty_inspector_t;
typedef struct ghostty_terminal* ghostty_terminal_t;
typedef struct ghostty_terminal_producer* ghostty_terminal_producer_t;
typedef struct ghostty_terminal_surface* ghostty_terminal_surface_t;

// Opaque handles for the sans-I/O tmux control-mode embedding API.
typedef struct ghostty_tmux_client* ghostty_tmux_client_t;
typedef const struct ghostty_tmux_topology_view* ghostty_tmux_topology_view_t;

// All the types below are fully defined and must be kept in sync with
// their Zig counterparts. Any changes to these types MUST have an associated
// Zig change.
typedef enum {
  GHOSTTY_PLATFORM_INVALID,
  GHOSTTY_PLATFORM_MACOS,
  GHOSTTY_PLATFORM_IOS,
} ghostty_platform_e;

typedef enum {
  GHOSTTY_CLIPBOARD_STANDARD,
  GHOSTTY_CLIPBOARD_SELECTION,
} ghostty_clipboard_e;

typedef struct {
  const char *mime;
  const char *data;
} ghostty_clipboard_content_s;

typedef enum {
  GHOSTTY_CLIPBOARD_REQUEST_PASTE,
  GHOSTTY_CLIPBOARD_REQUEST_OSC_52_READ,
  GHOSTTY_CLIPBOARD_REQUEST_OSC_52_WRITE,
} ghostty_clipboard_request_e;

typedef enum {
  GHOSTTY_MOUSE_RELEASE,
  GHOSTTY_MOUSE_PRESS,
} ghostty_input_mouse_state_e;

typedef enum {
  GHOSTTY_MOUSE_UNKNOWN,
  GHOSTTY_MOUSE_LEFT,
  GHOSTTY_MOUSE_RIGHT,
  GHOSTTY_MOUSE_MIDDLE,
  GHOSTTY_MOUSE_FOUR,
  GHOSTTY_MOUSE_FIVE,
  GHOSTTY_MOUSE_SIX,
  GHOSTTY_MOUSE_SEVEN,
  GHOSTTY_MOUSE_EIGHT,
  GHOSTTY_MOUSE_NINE,
  GHOSTTY_MOUSE_TEN,
  GHOSTTY_MOUSE_ELEVEN,
} ghostty_input_mouse_button_e;

typedef enum {
  GHOSTTY_MOUSE_MOMENTUM_NONE,
  GHOSTTY_MOUSE_MOMENTUM_BEGAN,
  GHOSTTY_MOUSE_MOMENTUM_STATIONARY,
  GHOSTTY_MOUSE_MOMENTUM_CHANGED,
  GHOSTTY_MOUSE_MOMENTUM_ENDED,
  GHOSTTY_MOUSE_MOMENTUM_CANCELLED,
  GHOSTTY_MOUSE_MOMENTUM_MAY_BEGIN,
} ghostty_input_mouse_momentum_e;

typedef enum {
  GHOSTTY_COLOR_SCHEME_LIGHT = 0,
  GHOSTTY_COLOR_SCHEME_DARK = 1,
} ghostty_color_scheme_e;

// This is a packed struct (see src/input/mouse.zig) but the C standard
// afaik doesn't let us reliably define packed structs so we build it up
// from scratch.
typedef int ghostty_input_scroll_mods_t;

typedef enum {
  GHOSTTY_MODS_NONE = 0,
  GHOSTTY_MODS_SHIFT = 1 << 0,
  GHOSTTY_MODS_CTRL = 1 << 1,
  GHOSTTY_MODS_ALT = 1 << 2,
  GHOSTTY_MODS_SUPER = 1 << 3,
  GHOSTTY_MODS_CAPS = 1 << 4,
  GHOSTTY_MODS_NUM = 1 << 5,
  GHOSTTY_MODS_SHIFT_RIGHT = 1 << 6,
  GHOSTTY_MODS_CTRL_RIGHT = 1 << 7,
  GHOSTTY_MODS_ALT_RIGHT = 1 << 8,
  GHOSTTY_MODS_SUPER_RIGHT = 1 << 9,
} ghostty_input_mods_e;

typedef enum {
  GHOSTTY_BINDING_FLAGS_CONSUMED = 1 << 0,
  GHOSTTY_BINDING_FLAGS_ALL = 1 << 1,
  GHOSTTY_BINDING_FLAGS_GLOBAL = 1 << 2,
  GHOSTTY_BINDING_FLAGS_PERFORMABLE = 1 << 3,
} ghostty_binding_flags_e;

typedef enum {
  GHOSTTY_ACTION_RELEASE,
  GHOSTTY_ACTION_PRESS,
  GHOSTTY_ACTION_REPEAT,
} ghostty_input_action_e;

// Based on: https://www.w3.org/TR/uievents-code/
typedef enum {
  GHOSTTY_KEY_UNIDENTIFIED,

  // "Writing System Keys" § 3.1.1
  GHOSTTY_KEY_BACKQUOTE,
  GHOSTTY_KEY_BACKSLASH,
  GHOSTTY_KEY_BRACKET_LEFT,
  GHOSTTY_KEY_BRACKET_RIGHT,
  GHOSTTY_KEY_COMMA,
  GHOSTTY_KEY_DIGIT_0,
  GHOSTTY_KEY_DIGIT_1,
  GHOSTTY_KEY_DIGIT_2,
  GHOSTTY_KEY_DIGIT_3,
  GHOSTTY_KEY_DIGIT_4,
  GHOSTTY_KEY_DIGIT_5,
  GHOSTTY_KEY_DIGIT_6,
  GHOSTTY_KEY_DIGIT_7,
  GHOSTTY_KEY_DIGIT_8,
  GHOSTTY_KEY_DIGIT_9,
  GHOSTTY_KEY_EQUAL,
  GHOSTTY_KEY_INTL_BACKSLASH,
  GHOSTTY_KEY_INTL_RO,
  GHOSTTY_KEY_INTL_YEN,
  GHOSTTY_KEY_A,
  GHOSTTY_KEY_B,
  GHOSTTY_KEY_C,
  GHOSTTY_KEY_D,
  GHOSTTY_KEY_E,
  GHOSTTY_KEY_F,
  GHOSTTY_KEY_G,
  GHOSTTY_KEY_H,
  GHOSTTY_KEY_I,
  GHOSTTY_KEY_J,
  GHOSTTY_KEY_K,
  GHOSTTY_KEY_L,
  GHOSTTY_KEY_M,
  GHOSTTY_KEY_N,
  GHOSTTY_KEY_O,
  GHOSTTY_KEY_P,
  GHOSTTY_KEY_Q,
  GHOSTTY_KEY_R,
  GHOSTTY_KEY_S,
  GHOSTTY_KEY_T,
  GHOSTTY_KEY_U,
  GHOSTTY_KEY_V,
  GHOSTTY_KEY_W,
  GHOSTTY_KEY_X,
  GHOSTTY_KEY_Y,
  GHOSTTY_KEY_Z,
  GHOSTTY_KEY_MINUS,
  GHOSTTY_KEY_PERIOD,
  GHOSTTY_KEY_QUOTE,
  GHOSTTY_KEY_SEMICOLON,
  GHOSTTY_KEY_SLASH,

  // "Functional Keys" § 3.1.2
  GHOSTTY_KEY_ALT_LEFT,
  GHOSTTY_KEY_ALT_RIGHT,
  GHOSTTY_KEY_BACKSPACE,
  GHOSTTY_KEY_CAPS_LOCK,
  GHOSTTY_KEY_CONTEXT_MENU,
  GHOSTTY_KEY_CONTROL_LEFT,
  GHOSTTY_KEY_CONTROL_RIGHT,
  GHOSTTY_KEY_ENTER,
  GHOSTTY_KEY_META_LEFT,
  GHOSTTY_KEY_META_RIGHT,
  GHOSTTY_KEY_SHIFT_LEFT,
  GHOSTTY_KEY_SHIFT_RIGHT,
  GHOSTTY_KEY_SPACE,
  GHOSTTY_KEY_TAB,
  GHOSTTY_KEY_CONVERT,
  GHOSTTY_KEY_KANA_MODE,
  GHOSTTY_KEY_NON_CONVERT,

  // "Control Pad Section" § 3.2
  GHOSTTY_KEY_DELETE,
  GHOSTTY_KEY_END,
  GHOSTTY_KEY_HELP,
  GHOSTTY_KEY_HOME,
  GHOSTTY_KEY_INSERT,
  GHOSTTY_KEY_PAGE_DOWN,
  GHOSTTY_KEY_PAGE_UP,

  // "Arrow Pad Section" § 3.3
  GHOSTTY_KEY_ARROW_DOWN,
  GHOSTTY_KEY_ARROW_LEFT,
  GHOSTTY_KEY_ARROW_RIGHT,
  GHOSTTY_KEY_ARROW_UP,

  // "Numpad Section" § 3.4
  GHOSTTY_KEY_NUM_LOCK,
  GHOSTTY_KEY_NUMPAD_0,
  GHOSTTY_KEY_NUMPAD_1,
  GHOSTTY_KEY_NUMPAD_2,
  GHOSTTY_KEY_NUMPAD_3,
  GHOSTTY_KEY_NUMPAD_4,
  GHOSTTY_KEY_NUMPAD_5,
  GHOSTTY_KEY_NUMPAD_6,
  GHOSTTY_KEY_NUMPAD_7,
  GHOSTTY_KEY_NUMPAD_8,
  GHOSTTY_KEY_NUMPAD_9,
  GHOSTTY_KEY_NUMPAD_ADD,
  GHOSTTY_KEY_NUMPAD_BACKSPACE,
  GHOSTTY_KEY_NUMPAD_CLEAR,
  GHOSTTY_KEY_NUMPAD_CLEAR_ENTRY,
  GHOSTTY_KEY_NUMPAD_COMMA,
  GHOSTTY_KEY_NUMPAD_DECIMAL,
  GHOSTTY_KEY_NUMPAD_DIVIDE,
  GHOSTTY_KEY_NUMPAD_ENTER,
  GHOSTTY_KEY_NUMPAD_EQUAL,
  GHOSTTY_KEY_NUMPAD_MEMORY_ADD,
  GHOSTTY_KEY_NUMPAD_MEMORY_CLEAR,
  GHOSTTY_KEY_NUMPAD_MEMORY_RECALL,
  GHOSTTY_KEY_NUMPAD_MEMORY_STORE,
  GHOSTTY_KEY_NUMPAD_MEMORY_SUBTRACT,
  GHOSTTY_KEY_NUMPAD_MULTIPLY,
  GHOSTTY_KEY_NUMPAD_PAREN_LEFT,
  GHOSTTY_KEY_NUMPAD_PAREN_RIGHT,
  GHOSTTY_KEY_NUMPAD_SUBTRACT,
  GHOSTTY_KEY_NUMPAD_SEPARATOR,
  GHOSTTY_KEY_NUMPAD_UP,
  GHOSTTY_KEY_NUMPAD_DOWN,
  GHOSTTY_KEY_NUMPAD_RIGHT,
  GHOSTTY_KEY_NUMPAD_LEFT,
  GHOSTTY_KEY_NUMPAD_BEGIN,
  GHOSTTY_KEY_NUMPAD_HOME,
  GHOSTTY_KEY_NUMPAD_END,
  GHOSTTY_KEY_NUMPAD_INSERT,
  GHOSTTY_KEY_NUMPAD_DELETE,
  GHOSTTY_KEY_NUMPAD_PAGE_UP,
  GHOSTTY_KEY_NUMPAD_PAGE_DOWN,

  // "Function Section" § 3.5
  GHOSTTY_KEY_ESCAPE,
  GHOSTTY_KEY_F1,
  GHOSTTY_KEY_F2,
  GHOSTTY_KEY_F3,
  GHOSTTY_KEY_F4,
  GHOSTTY_KEY_F5,
  GHOSTTY_KEY_F6,
  GHOSTTY_KEY_F7,
  GHOSTTY_KEY_F8,
  GHOSTTY_KEY_F9,
  GHOSTTY_KEY_F10,
  GHOSTTY_KEY_F11,
  GHOSTTY_KEY_F12,
  GHOSTTY_KEY_F13,
  GHOSTTY_KEY_F14,
  GHOSTTY_KEY_F15,
  GHOSTTY_KEY_F16,
  GHOSTTY_KEY_F17,
  GHOSTTY_KEY_F18,
  GHOSTTY_KEY_F19,
  GHOSTTY_KEY_F20,
  GHOSTTY_KEY_F21,
  GHOSTTY_KEY_F22,
  GHOSTTY_KEY_F23,
  GHOSTTY_KEY_F24,
  GHOSTTY_KEY_F25,
  GHOSTTY_KEY_FN,
  GHOSTTY_KEY_FN_LOCK,
  GHOSTTY_KEY_PRINT_SCREEN,
  GHOSTTY_KEY_SCROLL_LOCK,
  GHOSTTY_KEY_PAUSE,

  // "Media Keys" § 3.6
  GHOSTTY_KEY_BROWSER_BACK,
  GHOSTTY_KEY_BROWSER_FAVORITES,
  GHOSTTY_KEY_BROWSER_FORWARD,
  GHOSTTY_KEY_BROWSER_HOME,
  GHOSTTY_KEY_BROWSER_REFRESH,
  GHOSTTY_KEY_BROWSER_SEARCH,
  GHOSTTY_KEY_BROWSER_STOP,
  GHOSTTY_KEY_EJECT,
  GHOSTTY_KEY_LAUNCH_APP_1,
  GHOSTTY_KEY_LAUNCH_APP_2,
  GHOSTTY_KEY_LAUNCH_MAIL,
  GHOSTTY_KEY_MEDIA_PLAY_PAUSE,
  GHOSTTY_KEY_MEDIA_SELECT,
  GHOSTTY_KEY_MEDIA_STOP,
  GHOSTTY_KEY_MEDIA_TRACK_NEXT,
  GHOSTTY_KEY_MEDIA_TRACK_PREVIOUS,
  GHOSTTY_KEY_POWER,
  GHOSTTY_KEY_SLEEP,
  GHOSTTY_KEY_AUDIO_VOLUME_DOWN,
  GHOSTTY_KEY_AUDIO_VOLUME_MUTE,
  GHOSTTY_KEY_AUDIO_VOLUME_UP,
  GHOSTTY_KEY_WAKE_UP,

  // "Legacy, Non-standard, and Special Keys" § 3.7
  GHOSTTY_KEY_COPY,
  GHOSTTY_KEY_CUT,
  GHOSTTY_KEY_PASTE,
} ghostty_input_key_e;

typedef struct {
  ghostty_input_action_e action;
  ghostty_input_mods_e mods;
  ghostty_input_mods_e consumed_mods;
  uint32_t keycode;
  const char* text;
  uint32_t unshifted_codepoint;
  bool composing;
} ghostty_input_key_s;

typedef enum {
  GHOSTTY_TRIGGER_PHYSICAL,
  GHOSTTY_TRIGGER_UNICODE,
  GHOSTTY_TRIGGER_CATCH_ALL,
} ghostty_input_trigger_tag_e;

typedef union {
  ghostty_input_key_e physical;
  uint32_t unicode;
  // catch_all has no payload
} ghostty_input_trigger_key_u;

typedef struct {
  ghostty_input_trigger_tag_e tag;
  ghostty_input_trigger_key_u key;
  ghostty_input_mods_e mods;
} ghostty_input_trigger_s;

typedef struct {
  const char* action_key;
  const char* action;
  const char* title;
  const char* description;
} ghostty_command_s;

typedef enum {
  GHOSTTY_BUILD_MODE_DEBUG,
  GHOSTTY_BUILD_MODE_RELEASE_SAFE,
  GHOSTTY_BUILD_MODE_RELEASE_FAST,
  GHOSTTY_BUILD_MODE_RELEASE_SMALL,
} ghostty_build_mode_e;

typedef struct {
  ghostty_build_mode_e build_mode;
  const char* version;
  uintptr_t version_len;
} ghostty_info_s;

typedef struct {
  const char* message;
} ghostty_diagnostic_s;

typedef struct {
  const char* ptr;
  uintptr_t len;
  bool sentinel;
} ghostty_string_s;

typedef struct {
  double tl_px_x;
  double tl_px_y;
  uint32_t offset_start;
  uint32_t offset_len;
  const char* text;
  uintptr_t text_len;
} ghostty_text_s;

typedef enum {
  GHOSTTY_POINT_ACTIVE,
  GHOSTTY_POINT_VIEWPORT,
  GHOSTTY_POINT_SCREEN,
  GHOSTTY_POINT_SURFACE,
} ghostty_point_tag_e;

typedef enum {
  GHOSTTY_POINT_COORD_EXACT,
  GHOSTTY_POINT_COORD_TOP_LEFT,
  GHOSTTY_POINT_COORD_BOTTOM_RIGHT,
} ghostty_point_coord_e;

typedef struct {
  ghostty_point_tag_e tag;
  ghostty_point_coord_e coord;
  uint32_t x;
  uint32_t y;
} ghostty_point_s;

typedef struct {
  ghostty_point_s top_left;
  ghostty_point_s bottom_right;
  bool rectangle;
} ghostty_selection_s;

typedef struct {
  const char* key;
  const char* value;
} ghostty_env_var_s;

typedef struct {
  void* nsview;
} ghostty_platform_macos_s;

typedef struct {
  void* uiview;
} ghostty_platform_ios_s;

typedef union {
  ghostty_platform_macos_s macos;
  ghostty_platform_ios_s ios;
} ghostty_platform_u;

typedef enum {
  GHOSTTY_SURFACE_CONTEXT_WINDOW = 0,
  GHOSTTY_SURFACE_CONTEXT_TAB = 1,
  GHOSTTY_SURFACE_CONTEXT_SPLIT = 2,
} ghostty_surface_context_e;

typedef struct {
  ghostty_platform_e platform_tag;
  ghostty_platform_u platform;
  void* userdata;
  double scale_factor;
  float font_size;
  const char* working_directory;
  const char* command;
  ghostty_env_var_s* env_vars;
  size_t env_var_count;
  const char* initial_input;
  bool wait_after_command;
  ghostty_surface_context_e context;
} ghostty_surface_config_s;

typedef struct {
  uint16_t columns;
  uint16_t rows;
  uint32_t width_px;
  uint32_t height_px;
  uint32_t cell_width_px;
  uint32_t cell_height_px;
} ghostty_surface_size_s;

// tmux control-mode embedding types

typedef enum {
  GHOSTTY_TMUX_RESULT_OK,
  GHOSTTY_TMUX_RESULT_INVALID_INPUT,
  GHOSTTY_TMUX_RESULT_OUT_OF_MEMORY,
  GHOSTTY_TMUX_RESULT_NOT_READY,
  GHOSTTY_TMUX_RESULT_CLOSED,
  GHOSTTY_TMUX_RESULT_CLIENT_FAILED,
  GHOSTTY_TMUX_RESULT_REENTRANT_FEED,
  GHOSTTY_TMUX_RESULT_INVALID_COMMAND,
  GHOSTTY_TMUX_RESULT_TOKEN_EXHAUSTED,
  GHOSTTY_TMUX_RESULT_INVALID_CONSUMPTION,
  GHOSTTY_TMUX_RESULT_PANE_UNKNOWN,
  GHOSTTY_TMUX_RESULT_CALLBACK_ACTIVE,
} ghostty_tmux_result_e;

typedef struct {
  const uint8_t* ptr;
  size_t len;
} ghostty_tmux_bytes_s;

typedef enum {
  GHOSTTY_TMUX_ACTION_EXIT,
  GHOSTTY_TMUX_ACTION_TOPOLOGY,
  GHOSTTY_TMUX_ACTION_PANE_CHANGED,
  GHOSTTY_TMUX_ACTION_COMMAND_COMPLETE,
  GHOSTTY_TMUX_ACTION_INPUT_FAILED,
} ghostty_tmux_action_tag_e;

typedef enum {
  GHOSTTY_TMUX_EXIT_SERVER,
  GHOSTTY_TMUX_EXIT_UNSUPPORTED_VERSION,
  GHOSTTY_TMUX_EXIT_CLIENT_FAILURE,
} ghostty_tmux_exit_reason_e;

typedef enum {
  GHOSTTY_TMUX_COMMAND_SUCCESS,
  GHOSTTY_TMUX_COMMAND_ERROR_BLOCK,
  GHOSTTY_TMUX_COMMAND_SKIPPED,
} ghostty_tmux_command_status_e;

typedef enum {
  GHOSTTY_TMUX_PANE_HYDRATING,
  GHOSTTY_TMUX_PANE_LIVE,
} ghostty_tmux_pane_phase_e;

typedef enum {
  GHOSTTY_TMUX_TOPOLOGY_WINDOW,
  GHOSTTY_TMUX_TOPOLOGY_PANE,
} ghostty_tmux_topology_record_tag_e;

typedef struct {
  uint64_t id;
  bool active;
  bool zoomed;
  size_t width;
  size_t height;
  uint64_t active_pane_id;
} ghostty_tmux_window_record_s;

typedef struct {
  uint64_t id;
  uint64_t window_id;
  size_t x;
  size_t y;
  size_t width;
  size_t height;
  ghostty_tmux_pane_phase_e phase;
} ghostty_tmux_pane_record_s;

typedef union {
  ghostty_tmux_window_record_s window;
  ghostty_tmux_pane_record_s pane;
} ghostty_tmux_topology_record_u;

typedef struct {
  ghostty_tmux_topology_record_tag_e tag;
  ghostty_tmux_topology_record_u value;
} ghostty_tmux_topology_record_s;

typedef struct {
  uint64_t token;
  ghostty_tmux_command_status_e status;
  ghostty_tmux_bytes_s body;
  uint64_t cause_token;
} ghostty_tmux_command_completion_s;

typedef struct {
  ghostty_tmux_topology_view_t view;
  ghostty_tmux_bytes_s session_name;
} ghostty_tmux_topology_action_s;

typedef struct {
  ghostty_tmux_exit_reason_e reason;
  // Human-readable tmux %exit detail for SERVER, the rejected version for
  // UNSUPPORTED_VERSION, and empty for CLIENT_FAILURE.
  ghostty_tmux_bytes_s detail;
} ghostty_tmux_exit_action_s;

typedef union {
  ghostty_tmux_exit_action_s exit;
  ghostty_tmux_topology_action_s topology;
  uint64_t pane_id;
  ghostty_tmux_command_completion_s command;
  ghostty_tmux_bytes_s input_failure;
} ghostty_tmux_action_u;

typedef struct {
  ghostty_tmux_action_tag_e tag;
  ghostty_tmux_action_u value;
} ghostty_tmux_action_s;

typedef void (*ghostty_tmux_action_cb)(void*, const ghostty_tmux_action_s*);
typedef void (*ghostty_tmux_topology_visitor_cb)(
    void*,
    const ghostty_tmux_topology_record_s*);

typedef struct {
  void* userdata;
  ghostty_tmux_action_cb action_cb;
  // Unset requests all available remote history. Set with zero skips the
  // remote history capture.
  bool history_line_limit_is_set;
  size_t history_line_limit;
  // Local terminal scrollback capacity in bytes. Zero disables scrollback.
  size_t max_scrollback;
  // Optional initial control-client grid. Zero/zero leaves sizing to tmux;
  // otherwise both dimensions must be nonzero.
  uint16_t initial_columns;
  uint16_t initial_rows;
} ghostty_tmux_client_config_s;

// Config types

// config.Path
typedef struct {
  const char* path;
  bool optional;
} ghostty_config_path_s;

// config.Color
typedef struct {
  uint8_t r;
  uint8_t g;
  uint8_t b;
} ghostty_config_color_s;

// config.ColorList
typedef struct {
  const ghostty_config_color_s* colors;
  size_t len;
} ghostty_config_color_list_s;

// config.RepeatableCommand
typedef struct {
  const ghostty_command_s* commands;
  size_t len;
} ghostty_config_command_list_s;

// config.Palette
typedef struct {
  ghostty_config_color_s colors[256];
} ghostty_config_palette_s;

// config.QuickTerminalSize
typedef enum {
  GHOSTTY_QUICK_TERMINAL_SIZE_NONE,
  GHOSTTY_QUICK_TERMINAL_SIZE_PERCENTAGE,
  GHOSTTY_QUICK_TERMINAL_SIZE_PIXELS,
} ghostty_quick_terminal_size_tag_e;

typedef union {
  float percentage;
  uint32_t pixels;
} ghostty_quick_terminal_size_value_u;

typedef struct {
  ghostty_quick_terminal_size_tag_e tag;
  ghostty_quick_terminal_size_value_u value;
} ghostty_quick_terminal_size_s;

typedef struct {
  ghostty_quick_terminal_size_s primary;
  ghostty_quick_terminal_size_s secondary;
} ghostty_config_quick_terminal_size_s;

// config.Fullscreen
typedef enum {
  GHOSTTY_CONFIG_FULLSCREEN_FALSE,
  GHOSTTY_CONFIG_FULLSCREEN_TRUE,
  GHOSTTY_CONFIG_FULLSCREEN_NON_NATIVE,
  GHOSTTY_CONFIG_FULLSCREEN_NON_NATIVE_VISIBLE_MENU,
  GHOSTTY_CONFIG_FULLSCREEN_NON_NATIVE_PADDED_NOTCH,
} ghostty_config_fullscreen_e;

// apprt.Target.Key
typedef enum {
  GHOSTTY_TARGET_APP,
  GHOSTTY_TARGET_SURFACE,
} ghostty_target_tag_e;

typedef union {
  ghostty_surface_t surface;
} ghostty_target_u;

typedef struct {
  ghostty_target_tag_e tag;
  ghostty_target_u target;
} ghostty_target_s;

// apprt.action.SplitDirection
typedef enum {
  GHOSTTY_SPLIT_DIRECTION_RIGHT,
  GHOSTTY_SPLIT_DIRECTION_DOWN,
  GHOSTTY_SPLIT_DIRECTION_LEFT,
  GHOSTTY_SPLIT_DIRECTION_UP,
} ghostty_action_split_direction_e;

// apprt.action.GotoSplit
typedef enum {
  GHOSTTY_GOTO_SPLIT_PREVIOUS,
  GHOSTTY_GOTO_SPLIT_NEXT,
  GHOSTTY_GOTO_SPLIT_UP,
  GHOSTTY_GOTO_SPLIT_LEFT,
  GHOSTTY_GOTO_SPLIT_DOWN,
  GHOSTTY_GOTO_SPLIT_RIGHT,
} ghostty_action_goto_split_e;

// apprt.action.GotoWindow
typedef enum {
  GHOSTTY_GOTO_WINDOW_PREVIOUS,
  GHOSTTY_GOTO_WINDOW_NEXT,
} ghostty_action_goto_window_e;

// apprt.action.ResizeSplit.Direction
typedef enum {
  GHOSTTY_RESIZE_SPLIT_UP,
  GHOSTTY_RESIZE_SPLIT_DOWN,
  GHOSTTY_RESIZE_SPLIT_LEFT,
  GHOSTTY_RESIZE_SPLIT_RIGHT,
} ghostty_action_resize_split_direction_e;

// apprt.action.ResizeSplit
typedef struct {
  uint16_t amount;
  ghostty_action_resize_split_direction_e direction;
} ghostty_action_resize_split_s;

// apprt.action.MoveTab
typedef struct {
  ssize_t amount;
} ghostty_action_move_tab_s;

// apprt.action.GotoTab
typedef enum {
  GHOSTTY_GOTO_TAB_PREVIOUS = -1,
  GHOSTTY_GOTO_TAB_NEXT = -2,
  GHOSTTY_GOTO_TAB_LAST = -3,
} ghostty_action_goto_tab_e;

// apprt.action.Fullscreen
typedef enum {
  GHOSTTY_FULLSCREEN_NATIVE,
  GHOSTTY_FULLSCREEN_MACOS_NON_NATIVE,
  GHOSTTY_FULLSCREEN_MACOS_NON_NATIVE_VISIBLE_MENU,
  GHOSTTY_FULLSCREEN_MACOS_NON_NATIVE_PADDED_NOTCH,
} ghostty_action_fullscreen_e;

// apprt.action.FloatWindow
typedef enum {
  GHOSTTY_FLOAT_WINDOW_ON,
  GHOSTTY_FLOAT_WINDOW_OFF,
  GHOSTTY_FLOAT_WINDOW_TOGGLE,
} ghostty_action_float_window_e;

// apprt.action.SecureInput
typedef enum {
  GHOSTTY_SECURE_INPUT_ON,
  GHOSTTY_SECURE_INPUT_OFF,
  GHOSTTY_SECURE_INPUT_TOGGLE,
} ghostty_action_secure_input_e;

// apprt.action.Inspector
typedef enum {
  GHOSTTY_INSPECTOR_TOGGLE,
  GHOSTTY_INSPECTOR_SHOW,
  GHOSTTY_INSPECTOR_HIDE,
} ghostty_action_inspector_e;

// apprt.action.QuitTimer
typedef enum {
  GHOSTTY_QUIT_TIMER_START,
  GHOSTTY_QUIT_TIMER_STOP,
} ghostty_action_quit_timer_e;

// apprt.action.Readonly
typedef enum {
  GHOSTTY_READONLY_OFF,
  GHOSTTY_READONLY_ON,
} ghostty_action_readonly_e;

// apprt.action.DesktopNotification.C
typedef struct {
  const char* title;
  const char* body;
} ghostty_action_desktop_notification_s;

// apprt.action.SetTitle.C
typedef struct {
  const char* title;
} ghostty_action_set_title_s;

// apprt.action.PromptTitle
typedef enum {
  GHOSTTY_PROMPT_TITLE_SURFACE,
  GHOSTTY_PROMPT_TITLE_TAB,
} ghostty_action_prompt_title_e;

// apprt.action.Pwd.C
typedef struct {
  const char* pwd;
} ghostty_action_pwd_s;

// terminal.MouseShape
typedef enum {
  GHOSTTY_MOUSE_SHAPE_DEFAULT,
  GHOSTTY_MOUSE_SHAPE_CONTEXT_MENU,
  GHOSTTY_MOUSE_SHAPE_HELP,
  GHOSTTY_MOUSE_SHAPE_POINTER,
  GHOSTTY_MOUSE_SHAPE_PROGRESS,
  GHOSTTY_MOUSE_SHAPE_WAIT,
  GHOSTTY_MOUSE_SHAPE_CELL,
  GHOSTTY_MOUSE_SHAPE_CROSSHAIR,
  GHOSTTY_MOUSE_SHAPE_TEXT,
  GHOSTTY_MOUSE_SHAPE_VERTICAL_TEXT,
  GHOSTTY_MOUSE_SHAPE_ALIAS,
  GHOSTTY_MOUSE_SHAPE_COPY,
  GHOSTTY_MOUSE_SHAPE_MOVE,
  GHOSTTY_MOUSE_SHAPE_NO_DROP,
  GHOSTTY_MOUSE_SHAPE_NOT_ALLOWED,
  GHOSTTY_MOUSE_SHAPE_GRAB,
  GHOSTTY_MOUSE_SHAPE_GRABBING,
  GHOSTTY_MOUSE_SHAPE_ALL_SCROLL,
  GHOSTTY_MOUSE_SHAPE_COL_RESIZE,
  GHOSTTY_MOUSE_SHAPE_ROW_RESIZE,
  GHOSTTY_MOUSE_SHAPE_N_RESIZE,
  GHOSTTY_MOUSE_SHAPE_E_RESIZE,
  GHOSTTY_MOUSE_SHAPE_S_RESIZE,
  GHOSTTY_MOUSE_SHAPE_W_RESIZE,
  GHOSTTY_MOUSE_SHAPE_NE_RESIZE,
  GHOSTTY_MOUSE_SHAPE_NW_RESIZE,
  GHOSTTY_MOUSE_SHAPE_SE_RESIZE,
  GHOSTTY_MOUSE_SHAPE_SW_RESIZE,
  GHOSTTY_MOUSE_SHAPE_EW_RESIZE,
  GHOSTTY_MOUSE_SHAPE_NS_RESIZE,
  GHOSTTY_MOUSE_SHAPE_NESW_RESIZE,
  GHOSTTY_MOUSE_SHAPE_NWSE_RESIZE,
  GHOSTTY_MOUSE_SHAPE_ZOOM_IN,
  GHOSTTY_MOUSE_SHAPE_ZOOM_OUT,
} ghostty_action_mouse_shape_e;

// apprt.action.MouseVisibility
typedef enum {
  GHOSTTY_MOUSE_VISIBLE,
  GHOSTTY_MOUSE_HIDDEN,
} ghostty_action_mouse_visibility_e;

// apprt.action.MouseOverLink
typedef struct {
  const char* url;
  size_t len;
} ghostty_action_mouse_over_link_s;

// apprt.action.SizeLimit
typedef struct {
  uint32_t min_width;
  uint32_t min_height;
  uint32_t max_width;
  uint32_t max_height;
} ghostty_action_size_limit_s;

// apprt.action.InitialSize
typedef struct {
  uint32_t width;
  uint32_t height;
} ghostty_action_initial_size_s;

// apprt.action.CellSize
typedef struct {
  uint32_t width;
  uint32_t height;
} ghostty_action_cell_size_s;

// renderer.Health
typedef enum {
  GHOSTTY_RENDERER_HEALTH_HEALTHY,
  GHOSTTY_RENDERER_HEALTH_UNHEALTHY,
} ghostty_action_renderer_health_e;

// Generic producer for a terminal without a PTY or subprocess.

typedef enum {
  GHOSTTY_TERMINAL_PRODUCER_RESULT_OK,
  GHOSTTY_TERMINAL_PRODUCER_RESULT_INVALID_INPUT,
  GHOSTTY_TERMINAL_PRODUCER_RESULT_OUT_OF_MEMORY,
} ghostty_terminal_producer_result_e;

typedef struct {
  uint16_t columns;
  uint16_t rows;
  size_t max_scrollback;
} ghostty_terminal_producer_config_s;

// Renderer-only surface over an externally supplied ghostty_terminal_t.

typedef enum {
  GHOSTTY_TERMINAL_SURFACE_RESULT_OK,
  GHOSTTY_TERMINAL_SURFACE_RESULT_INVALID_INPUT,
  GHOSTTY_TERMINAL_SURFACE_RESULT_OUT_OF_MEMORY,
  GHOSTTY_TERMINAL_SURFACE_RESULT_RENDERER_IN_USE,
  GHOSTTY_TERMINAL_SURFACE_RESULT_FAILED,
} ghostty_terminal_surface_result_e;

typedef enum {
  // The complete encoded payload was accepted by write_cb, or a read operation
  // returned its owned result.
  GHOSTTY_TERMINAL_SURFACE_INPUT_SENT,
  // The operation was valid but intentionally produced no payload. This also
  // covers local interaction and deduplicated remote mouse motion.
  GHOSTTY_TERMINAL_SURFACE_INPUT_CONSUMED_NO_OUTPUT,
  // The input was not locally accepted, was unencodable, or write_cb rejected
  // the complete payload.
  GHOSTTY_TERMINAL_SURFACE_INPUT_NOT_ACCEPTED,
  // No write_cb was configured.
  GHOSTTY_TERMINAL_SURFACE_INPUT_UNAVAILABLE,
  GHOSTTY_TERMINAL_SURFACE_INPUT_INVALID_INPUT,
  GHOSTTY_TERMINAL_SURFACE_INPUT_OUT_OF_MEMORY,
} ghostty_terminal_surface_input_result_e;

typedef struct {
  uint64_t total;
  uint64_t offset;
  uint64_t len;
  double cell_offset;
} ghostty_terminal_surface_scrollbar_s;

typedef enum {
  GHOSTTY_TERMINAL_SURFACE_SCROLL_ROUTE_VIEWPORT,
  GHOSTTY_TERMINAL_SURFACE_SCROLL_ROUTE_ALTERNATE_SCREEN_CURSOR,
  GHOSTTY_TERMINAL_SURFACE_SCROLL_ROUTE_REMOTE_MOUSE,
} ghostty_terminal_surface_scroll_route_e;

typedef struct {
  ghostty_terminal_surface_scrollbar_s scrollbar;
  ghostty_terminal_surface_scroll_route_e route;
  bool mouse_captured;
  bool has_selection;
} ghostty_terminal_surface_interaction_state_s;

// Called synchronously from draw or asynchronously from renderer/GPU completion
// work. The callback must be thread-safe and may only record the value or signal
// other work. It must not call any ghostty_terminal_surface_* function. Userdata
// must remain valid until ghostty_terminal_surface_free returns.
typedef void (*ghostty_terminal_surface_renderer_health_cb)(
    void*,
    ghostty_action_renderer_health_e);

// Called synchronously by terminal-surface input operations on the
// presentation-owner thread. The bytes are borrowed only for the callback;
// copy or enqueue them before returning true. True means the complete payload
// was admitted; false rejects it. The callback must not call any
// ghostty_terminal_surface_* function. write_cb and userdata must remain valid
// until ghostty_terminal_surface_free returns.
typedef bool (*ghostty_terminal_surface_write_cb)(
    void*,
    const uint8_t*,
    size_t);

typedef struct {
  ghostty_platform_e platform_tag;
  ghostty_platform_u platform;
  void* userdata;
  ghostty_terminal_surface_renderer_health_cb renderer_health_cb;
  ghostty_terminal_surface_write_cb write_cb;
  double scale_factor;
  float font_size;
  uint32_t width_px;
  uint32_t height_px;
  bool visible;
  bool focused;
} ghostty_terminal_surface_config_s;

// apprt.action.KeySequence
typedef struct {
  bool active;
  ghostty_input_trigger_s trigger;
} ghostty_action_key_sequence_s;

// apprt.action.KeyTable.Tag
typedef enum {
  GHOSTTY_KEY_TABLE_ACTIVATE,
  GHOSTTY_KEY_TABLE_DEACTIVATE,
  GHOSTTY_KEY_TABLE_DEACTIVATE_ALL,
} ghostty_action_key_table_tag_e;

// apprt.action.KeyTable.CValue
typedef union {
  struct {
    const char *name;
    size_t len;
  } activate;
} ghostty_action_key_table_u;

// apprt.action.KeyTable.C
typedef struct {
  ghostty_action_key_table_tag_e tag;
  ghostty_action_key_table_u value;
} ghostty_action_key_table_s;

// apprt.action.ColorKind
typedef enum {
  GHOSTTY_ACTION_COLOR_KIND_FOREGROUND = -1,
  GHOSTTY_ACTION_COLOR_KIND_BACKGROUND = -2,
  GHOSTTY_ACTION_COLOR_KIND_CURSOR = -3,
} ghostty_action_color_kind_e;

// apprt.action.ColorChange
typedef struct {
  ghostty_action_color_kind_e kind;
  uint8_t r;
  uint8_t g;
  uint8_t b;
} ghostty_action_color_change_s;

// apprt.action.ConfigChange
typedef struct {
  ghostty_config_t config;
} ghostty_action_config_change_s;

// apprt.action.ReloadConfig
typedef struct {
  bool soft;
} ghostty_action_reload_config_s;

// apprt.action.OpenUrlKind
typedef enum {
  GHOSTTY_ACTION_OPEN_URL_KIND_UNKNOWN,
  GHOSTTY_ACTION_OPEN_URL_KIND_TEXT,
  GHOSTTY_ACTION_OPEN_URL_KIND_HTML,
} ghostty_action_open_url_kind_e;

// apprt.action.OpenUrl.C
typedef struct {
  ghostty_action_open_url_kind_e kind;
  const char* url;
  uintptr_t len;
} ghostty_action_open_url_s;

// apprt.action.CloseTabMode
typedef enum {
  GHOSTTY_ACTION_CLOSE_TAB_MODE_THIS,
  GHOSTTY_ACTION_CLOSE_TAB_MODE_OTHER,
  GHOSTTY_ACTION_CLOSE_TAB_MODE_RIGHT,
} ghostty_action_close_tab_mode_e;

// apprt.surface.Message.ChildExited
typedef struct {
  uint32_t exit_code;
  uint64_t timetime_ms;
} ghostty_surface_message_childexited_s;

// terminal.osc.Command.ProgressReport.State
typedef enum {
  GHOSTTY_PROGRESS_STATE_REMOVE,
  GHOSTTY_PROGRESS_STATE_SET,
  GHOSTTY_PROGRESS_STATE_ERROR,
  GHOSTTY_PROGRESS_STATE_INDETERMINATE,
  GHOSTTY_PROGRESS_STATE_PAUSE,
} ghostty_action_progress_report_state_e;

// terminal.osc.Command.ProgressReport.C
typedef struct {
  ghostty_action_progress_report_state_e state;
  // -1 if no progress was reported, otherwise 0-100 indicating percent
  // completeness.
  int8_t progress;
} ghostty_action_progress_report_s;

// apprt.action.CommandFinished.C
typedef struct {
  // -1 if no exit code was reported, otherwise 0-255
  int16_t exit_code;
  // number of nanoseconds that command was running for
  uint64_t duration;
} ghostty_action_command_finished_s;

// apprt.action.StartSearch.C
typedef struct {
  const char* needle;
} ghostty_action_start_search_s;

// apprt.action.SearchTotal
typedef struct {
  ssize_t total;
} ghostty_action_search_total_s;

// apprt.action.SearchSelected
typedef struct {
  ssize_t selected;
} ghostty_action_search_selected_s;

// terminal.Scrollbar
typedef struct {
  uint64_t total;
  uint64_t offset;
  uint64_t len;
} ghostty_action_scrollbar_s;

// apprt.Action.Key
typedef enum {
  GHOSTTY_ACTION_QUIT,
  GHOSTTY_ACTION_NEW_WINDOW,
  GHOSTTY_ACTION_NEW_TAB,
  GHOSTTY_ACTION_CLOSE_TAB,
  GHOSTTY_ACTION_NEW_SPLIT,
  GHOSTTY_ACTION_CLOSE_ALL_WINDOWS,
  GHOSTTY_ACTION_TOGGLE_MAXIMIZE,
  GHOSTTY_ACTION_TOGGLE_FULLSCREEN,
  GHOSTTY_ACTION_TOGGLE_TAB_OVERVIEW,
  GHOSTTY_ACTION_TOGGLE_WINDOW_DECORATIONS,
  GHOSTTY_ACTION_TOGGLE_QUICK_TERMINAL,
  GHOSTTY_ACTION_TOGGLE_COMMAND_PALETTE,
  GHOSTTY_ACTION_TOGGLE_VISIBILITY,
  GHOSTTY_ACTION_TOGGLE_BACKGROUND_OPACITY,
  GHOSTTY_ACTION_MOVE_TAB,
  GHOSTTY_ACTION_GOTO_TAB,
  GHOSTTY_ACTION_GOTO_SPLIT,
  GHOSTTY_ACTION_GOTO_WINDOW,
  GHOSTTY_ACTION_RESIZE_SPLIT,
  GHOSTTY_ACTION_EQUALIZE_SPLITS,
  GHOSTTY_ACTION_TOGGLE_SPLIT_ZOOM,
  GHOSTTY_ACTION_PRESENT_TERMINAL,
  GHOSTTY_ACTION_SIZE_LIMIT,
  GHOSTTY_ACTION_RESET_WINDOW_SIZE,
  GHOSTTY_ACTION_INITIAL_SIZE,
  GHOSTTY_ACTION_CELL_SIZE,
  GHOSTTY_ACTION_SCROLLBAR,
  GHOSTTY_ACTION_RENDER,
  GHOSTTY_ACTION_INSPECTOR,
  GHOSTTY_ACTION_SHOW_GTK_INSPECTOR,
  GHOSTTY_ACTION_RENDER_INSPECTOR,
  GHOSTTY_ACTION_DESKTOP_NOTIFICATION,
  GHOSTTY_ACTION_SET_TITLE,
  GHOSTTY_ACTION_SET_TAB_TITLE,
  GHOSTTY_ACTION_PROMPT_TITLE,
  GHOSTTY_ACTION_PWD,
  GHOSTTY_ACTION_MOUSE_SHAPE,
  GHOSTTY_ACTION_MOUSE_VISIBILITY,
  GHOSTTY_ACTION_MOUSE_OVER_LINK,
  GHOSTTY_ACTION_RENDERER_HEALTH,
  GHOSTTY_ACTION_OPEN_CONFIG,
  GHOSTTY_ACTION_QUIT_TIMER,
  GHOSTTY_ACTION_FLOAT_WINDOW,
  GHOSTTY_ACTION_SECURE_INPUT,
  GHOSTTY_ACTION_KEY_SEQUENCE,
  GHOSTTY_ACTION_KEY_TABLE,
  GHOSTTY_ACTION_COLOR_CHANGE,
  GHOSTTY_ACTION_RELOAD_CONFIG,
  GHOSTTY_ACTION_CONFIG_CHANGE,
  GHOSTTY_ACTION_CLOSE_WINDOW,
  GHOSTTY_ACTION_RING_BELL,
  GHOSTTY_ACTION_SELECTION_CHANGED,
  GHOSTTY_ACTION_UNDO,
  GHOSTTY_ACTION_REDO,
  GHOSTTY_ACTION_CHECK_FOR_UPDATES,
  GHOSTTY_ACTION_OPEN_URL,
  GHOSTTY_ACTION_SHOW_CHILD_EXITED,
  GHOSTTY_ACTION_PROGRESS_REPORT,
  GHOSTTY_ACTION_SHOW_ON_SCREEN_KEYBOARD,
  GHOSTTY_ACTION_COMMAND_FINISHED,
  GHOSTTY_ACTION_START_SEARCH,
  GHOSTTY_ACTION_END_SEARCH,
  GHOSTTY_ACTION_SEARCH_TOTAL,
  GHOSTTY_ACTION_SEARCH_SELECTED,
  GHOSTTY_ACTION_READONLY,
  GHOSTTY_ACTION_COPY_TITLE_TO_CLIPBOARD,
} ghostty_action_tag_e;

typedef union {
  ghostty_action_split_direction_e new_split;
  ghostty_action_fullscreen_e toggle_fullscreen;
  ghostty_action_move_tab_s move_tab;
  ghostty_action_goto_tab_e goto_tab;
  ghostty_action_goto_split_e goto_split;
  ghostty_action_goto_window_e goto_window;
  ghostty_action_resize_split_s resize_split;
  ghostty_action_size_limit_s size_limit;
  ghostty_action_initial_size_s initial_size;
  ghostty_action_cell_size_s cell_size;
  ghostty_action_scrollbar_s scrollbar;
  ghostty_action_inspector_e inspector;
  ghostty_action_desktop_notification_s desktop_notification;
  ghostty_action_set_title_s set_title;
  ghostty_action_set_title_s set_tab_title;
  ghostty_action_prompt_title_e prompt_title;
  ghostty_action_pwd_s pwd;
  ghostty_action_mouse_shape_e mouse_shape;
  ghostty_action_mouse_visibility_e mouse_visibility;
  ghostty_action_mouse_over_link_s mouse_over_link;
  ghostty_action_renderer_health_e renderer_health;
  ghostty_action_quit_timer_e quit_timer;
  ghostty_action_float_window_e float_window;
  ghostty_action_secure_input_e secure_input;
  ghostty_action_key_sequence_s key_sequence;
  ghostty_action_key_table_s key_table;
  ghostty_action_color_change_s color_change;
  ghostty_action_reload_config_s reload_config;
  ghostty_action_config_change_s config_change;
  ghostty_action_open_url_s open_url;
  ghostty_action_close_tab_mode_e close_tab_mode;
  ghostty_surface_message_childexited_s child_exited;
  ghostty_action_progress_report_s progress_report;
  ghostty_action_command_finished_s command_finished;
  ghostty_action_start_search_s start_search;
  ghostty_action_search_total_s search_total;
  ghostty_action_search_selected_s search_selected;
  ghostty_action_readonly_e readonly;
} ghostty_action_u;

typedef struct {
  ghostty_action_tag_e tag;
  ghostty_action_u action;
} ghostty_action_s;

typedef void (*ghostty_runtime_wakeup_cb)(void*);
typedef bool (*ghostty_runtime_read_clipboard_cb)(void*,
                                                  ghostty_clipboard_e,
                                                  void*);
typedef void (*ghostty_runtime_confirm_read_clipboard_cb)(
    void*,
    const char*,
    void*,
    ghostty_clipboard_request_e);
typedef void (*ghostty_runtime_write_clipboard_cb)(void*,
                                                   ghostty_clipboard_e,
                                                   const ghostty_clipboard_content_s*,
                                                   size_t,
                                                   bool);
typedef void (*ghostty_runtime_close_surface_cb)(void*, bool);
typedef bool (*ghostty_runtime_action_cb)(ghostty_app_t,
                                          ghostty_target_s,
                                          ghostty_action_s);

typedef struct {
  void* userdata;
  bool supports_selection_clipboard;
  ghostty_runtime_wakeup_cb wakeup_cb;
  ghostty_runtime_action_cb action_cb;
  ghostty_runtime_read_clipboard_cb read_clipboard_cb;
  ghostty_runtime_confirm_read_clipboard_cb confirm_read_clipboard_cb;
  ghostty_runtime_write_clipboard_cb write_clipboard_cb;
  ghostty_runtime_close_surface_cb close_surface_cb;
} ghostty_runtime_config_s;

// apprt.ipc.Target.Key
typedef enum {
  GHOSTTY_IPC_TARGET_CLASS,
  GHOSTTY_IPC_TARGET_DETECT,
} ghostty_ipc_target_tag_e;

typedef union {
  char *klass;
} ghostty_ipc_target_u;

typedef struct {
  ghostty_ipc_target_tag_e tag;
  ghostty_ipc_target_u target;
} chostty_ipc_target_s;

// apprt.ipc.Action.NewWindow
typedef struct {
  // This should be a null terminated list of strings.
  const char **arguments;
} ghostty_ipc_action_new_window_s;

typedef union {
  ghostty_ipc_action_new_window_s new_window;
} ghostty_ipc_action_u;

// apprt.ipc.Action.Key
typedef enum {
  GHOSTTY_IPC_ACTION_NEW_WINDOW,
  GHOSTTY_IPC_ACTION_TOGGLE_QUICK_TERMINAL,
} ghostty_ipc_action_tag_e;

//-------------------------------------------------------------------
// Published API

GHOSTTY_API int ghostty_init(uintptr_t, char**);
GHOSTTY_API void ghostty_cli_try_action(void);
GHOSTTY_API ghostty_info_s ghostty_info(void);
GHOSTTY_API const char* ghostty_translate(const char*);
GHOSTTY_API void ghostty_string_free(ghostty_string_s);

// Returns the default producer configuration: 80 columns, 24 rows, and 10,000
// bytes of scrollback. Zero max_scrollback disables scrollback.
GHOSTTY_API ghostty_terminal_producer_config_s
ghostty_terminal_producer_config_new(void);
// Creates a new terminal and its persistent VT parser without a PTY,
// subprocess, transport, callbacks, or renderer. All calls for one producer
// must be serialized by the caller. Feed input is length-delimited, preserves
// parser state across calls, and does not notify renderers. After feeding a
// terminal with a live surface, the host calls
// ghostty_terminal_surface_terminal_changed explicitly.
GHOSTTY_API ghostty_terminal_producer_result_e ghostty_terminal_producer_new(
    const ghostty_terminal_producer_config_s*,
    ghostty_terminal_producer_t*);
// Returns the producer's canonical terminal with one retained reference. The
// caller releases it exactly once with ghostty_terminal_release. Producer,
// retained terminal, and terminal surface may be freed in any order.
GHOSTTY_API ghostty_terminal_producer_result_e
ghostty_terminal_producer_retain_terminal(
    ghostty_terminal_producer_t,
    ghostty_terminal_t*);
// Data is borrowed only for this call. A NULL data pointer is valid only when
// len is zero. Embedded NUL bytes are passed unchanged to the VT parser. The
// producer does not attach to or mutate other terminals.
GHOSTTY_API ghostty_terminal_producer_result_e ghostty_terminal_producer_feed(
    ghostty_terminal_producer_t,
    const uint8_t*,
    size_t);
GHOSTTY_API void ghostty_terminal_producer_free(ghostty_terminal_producer_t);
GHOSTTY_API void ghostty_terminal_release(ghostty_terminal_t);

// Sans-I/O tmux control-mode client. The host owns the transport and must
// serialize all calls for one client. Action payloads, exit details, command
// response bodies, input failure bodies, session names, and topology views are
// borrowed only for the action callback. The callback may visit topology,
// enqueue commands, send pane input, read outbound bytes, or retain a pane
// terminal.
// It must not feed, consume, or free the client. Reentrant feed is rejected;
// consume and free are rejected while a callback is active.
GHOSTTY_API ghostty_tmux_client_config_s ghostty_tmux_client_config_new(void);
GHOSTTY_API ghostty_tmux_result_e ghostty_tmux_client_new(
    const ghostty_tmux_client_config_s*,
    ghostty_tmux_client_t*);
GHOSTTY_API ghostty_tmux_result_e ghostty_tmux_client_free(
    ghostty_tmux_client_t);
GHOSTTY_API ghostty_tmux_result_e ghostty_tmux_client_feed(
    ghostty_tmux_client_t,
    const uint8_t*,
    size_t);

// The returned outbound bytes are borrowed until the next feed, enqueue,
// consume, or free call. Outbound read inside an action callback is valid only
// for that callback and is invalidated immediately by a callback enqueue; the
// active feed may also enqueue after the callback returns. Hosts should
// normally read outbound after feed returns. A transport may consume a
// successfully written prefix and retrieve the remaining suffix again.
GHOSTTY_API ghostty_tmux_result_e ghostty_tmux_client_outbound(
    ghostty_tmux_client_t,
    ghostty_tmux_bytes_s*);
GHOSTTY_API ghostty_tmux_result_e ghostty_tmux_client_consume(
    ghostty_tmux_client_t,
    size_t);

// A standalone command is emitted as one newline-delimited command group.
// Repeated calls share the same outbound buffer and may be written together.
GHOSTTY_API ghostty_tmux_result_e ghostty_tmux_client_enqueue_command(
    ghostty_tmux_client_t,
    ghostty_tmux_bytes_s,
    uint64_t*);

// Members are joined with semicolons into one dependent tmux command group.
// Each returned token receives an ordered completion. If one member errors,
// later members are reported as SKIPPED with cause_token identifying it.
GHOSTTY_API ghostty_tmux_result_e ghostty_tmux_client_enqueue_command_group(
    ghostty_tmux_client_t,
    const ghostty_tmux_bytes_s*,
    size_t,
    uint64_t*);

// Sends already-encoded terminal bytes to a known pane as one standalone
// send-keys -H command. Every byte is represented as two lowercase hex digits.
// Empty input is a successful no-op after client and pane validation. A tmux
// rejection is reported as GHOSTTY_TMUX_ACTION_INPUT_FAILED with a borrowed
// error body; successful responses do not emit an action.
GHOSTTY_API ghostty_tmux_result_e ghostty_tmux_client_send_pane_input(
    ghostty_tmux_client_t,
    uint64_t,
    const uint8_t*,
    size_t);

// The topology view is valid only during its topology action callback. The
// visitor receives each window followed by its panes in layout order.
GHOSTTY_API ghostty_tmux_result_e ghostty_tmux_topology_visit(
    ghostty_tmux_topology_view_t,
    void*,
    ghostty_tmux_topology_visitor_cb);

// A retained pane terminal is the canonical Ghostty terminal owned by the
// control client, not a copy. It may outlive its pane and client and must be
// released exactly once by the caller.
GHOSTTY_API ghostty_tmux_result_e ghostty_tmux_client_retain_pane_terminal(
    ghostty_tmux_client_t,
    uint64_t,
    ghostty_terminal_t*);

// Renderer-only surface over an existing terminal. The app supplies shared
// configuration and font resources and must outlive the surface. The platform
// view is unretained and must also outlive the surface. Creation snapshots the
// app configuration, theme, content scale, and keyboard-layout-derived
// OptionAsAlt policy; recreate the surface to adopt changes to any of them. The
// supplied terminal remains caller-owned because the surface retains its own
// reference.
//
// width_px and height_px are required exact nonzero backing-pixel dimensions of
// the already-sized platform view. These calls notify the renderer; they do not
// resize the native view. The host must resize the view first and then report
// matching dimensions.
//
// Presentation setters, input, draw, size, and free must be serialized by one
// presentation owner. terminal_changed may run concurrently after the terminal
// mutation was published under its mutex, but every such call must finish and no
// new call may begin before free. Free stops and joins the renderer before
// returning. Input callbacks must return before free begins. If terminal_changed
// or a presentation setter returns non-OK, its wake may have failed after work
// was admitted; a host keeping the surface must retry the same notification or
// value. Input never returns a failure after write_cb accepts bytes, because a
// retry would duplicate input; renderer wake failures are logged instead.
GHOSTTY_API ghostty_terminal_surface_config_s
ghostty_terminal_surface_config_new(void);

// Synchronously measures the exact geometry terminal_surface_new will use for
// the same dimensions, scale, font-size override, and unchanged app
// configuration. This only prepares font metrics and renderer geometry: it
// does not read or require the config's platform view, callbacks, userdata,
// terminal, renderer/GPU resources, or native view. Inputs are borrowed for the
// call and out is written only on success. Call this on the app/presentation-
// owner thread and serialize it with app config updates, app destruction, and
// all surface creation using the same app.
GHOSTTY_API ghostty_terminal_surface_result_e ghostty_terminal_surface_measure(
    ghostty_app_t,
    const ghostty_terminal_surface_config_s*,
    ghostty_surface_size_s*);

GHOSTTY_API ghostty_terminal_surface_result_e ghostty_terminal_surface_new(
    ghostty_app_t,
    ghostty_terminal_t,
    const ghostty_terminal_surface_config_s*,
    ghostty_terminal_surface_t*);
GHOSTTY_API void ghostty_terminal_surface_free(ghostty_terminal_surface_t);
GHOSTTY_API ghostty_terminal_surface_result_e ghostty_terminal_surface_draw(
    ghostty_terminal_surface_t);
GHOSTTY_API ghostty_terminal_surface_result_e
ghostty_terminal_surface_terminal_changed(ghostty_terminal_surface_t);
GHOSTTY_API ghostty_terminal_surface_result_e
ghostty_terminal_surface_set_visible(ghostty_terminal_surface_t, bool);
GHOSTTY_API ghostty_terminal_surface_result_e
ghostty_terminal_surface_set_focused(ghostty_terminal_surface_t, bool);
// Runtime dimensions must also be nonzero. Resize the platform view first and
// pass its matching backing-pixel dimensions.
GHOSTTY_API ghostty_terminal_surface_result_e ghostty_terminal_surface_set_size(
    ghostty_terminal_surface_t,
    uint32_t,
    uint32_t);
// columns and rows are the desired presentation grid. Resizing presentation
// never mutates the canonical terminal geometry.
GHOSTTY_API ghostty_terminal_surface_result_e ghostty_terminal_surface_size(
    ghostty_terminal_surface_t,
    ghostty_surface_size_s*);

// Returns one synchronized snapshot of scrollbar geometry, fractional top-row
// presentation offset, input routing, effective mouse capture, and selection.
GHOSTTY_API ghostty_terminal_surface_result_e
ghostty_terminal_surface_interaction_state(
    ghostty_terminal_surface_t,
    ghostty_terminal_surface_interaction_state_s*);

// Normalizes cell_offset into row carry plus [0, 1), clamps to the available
// scrollbar range, and returns the exact state published by the operation.
// Reaching the bottom resets cell_offset to zero. Non-finite offsets are
// invalid, as is a row that cannot be represented by the host address size.
// If renderer notification fails, the updated state remains published and is
// still written to the output pointer. Repeating the same position is a
// side-effect-free no-op and does not retry notification; call
// ghostty_terminal_surface_terminal_changed to retry the wake.
GHOSTTY_API ghostty_terminal_surface_result_e
ghostty_terminal_surface_scroll_to_position(
    ghostty_terminal_surface_t,
    uint64_t,
    double,
    ghostty_terminal_surface_interaction_state_s*);

// Filter modifiers for native text translation. Pass the original unfiltered
// modifiers in the following key event.
GHOSTTY_API ghostty_input_mods_e
ghostty_terminal_surface_key_translation_mods(
    ghostty_terminal_surface_t,
    ghostty_input_mods_e);

// Host/global keybindings remain the host's responsibility. This operation
// applies terminal keyboard modes, synchronously admits at most one complete
// payload through write_cb, then applies accepted-key selection/viewport
// effects. write_cb rejection, missing input, and unencodable keys do not
// mutate presentation state.
GHOSTTY_API ghostty_terminal_surface_input_result_e
ghostty_terminal_surface_key(
    ghostty_terminal_surface_t,
    ghostty_input_key_s);

// Already-committed text without a physical key event, such as software-
// keyboard or IME output. Accepted nonempty length-delimited bytes are admitted
// unchanged through exactly one write_cb invocation: no key encoding or paste
// transformation is applied, and embedded NUL and control bytes are supported.
// Physical keys must use terminal_surface_key so terminal keyboard protocols
// are honored; clipboard paste must use terminal_surface_paste so paste modes
// are honored. A NULL pointer is valid only when len is 0; empty input is
// CONSUMED_NO_OUTPUT and does not invoke write_cb or mutate presentation state.
// When the creation snapshot permits KAM and the terminal enables it, nonempty
// input is also consumed without write_cb. Only accepted input applies the
// configured selection-clear and keystroke scroll-to-bottom presentation
// effects; unavailable or rejected input mutates nothing.
GHOSTTY_API ghostty_terminal_surface_input_result_e
ghostty_terminal_surface_input(
    ghostty_terminal_surface_t,
    const uint8_t*,
    size_t);

// Clipboard access and unsafe-paste confirmation remain host policy. Embedded
// NUL is supported. Prefix, transformed body, and suffix are admitted through
// exactly one write_cb invocation. A NULL pointer is valid only when len is 0;
// empty paste is CONSUMED_NO_OUTPUT and does not invoke write_cb or mutate the
// viewport.
GHOSTTY_API ghostty_terminal_surface_input_result_e
ghostty_terminal_surface_paste(
    ghostty_terminal_surface_t,
    const uint8_t*,
    size_t);

// Update the interaction pointer and modifiers used by remote mouse reporting,
// scrolling, and local selection. When terminal mouse reporting is active,
// motion is cell-deduplicated and the complete encoding is admitted through at
// most one write_cb invocation.
GHOSTTY_API ghostty_terminal_surface_input_result_e
ghostty_terminal_surface_mouse_pos(
    ghostty_terminal_surface_t,
    double,
    double,
    ghostty_input_mods_e);

// Remotely captured buttons are encoded through write_cb. Without capture,
// only the left button is accepted and drives terminal text selection.
GHOSTTY_API ghostty_terminal_surface_input_result_e
ghostty_terminal_surface_mouse_button(
    ghostty_terminal_surface_t,
    ghostty_input_mouse_state_e,
    ghostty_input_mouse_button_e,
    ghostty_input_mods_e);

// Negative deltas are down/left and positive deltas are up/right. Precise input
// is accumulated until it reaches a cell; non-precision input follows Ghostty's
// platform wheel-tick behavior. Alternate-screen cursor input and remote wheel
// reports each use at most one complete write_cb payload.
GHOSTTY_API ghostty_terminal_surface_input_result_e
ghostty_terminal_surface_mouse_scroll(
    ghostty_terminal_surface_t,
    double,
    double,
    ghostty_input_scroll_mods_t);

// Pressure is a local selection affordance only; it is never reported to a
// terminal application.
GHOSTTY_API ghostty_terminal_surface_input_result_e
ghostty_terminal_surface_mouse_pressure(
    ghostty_terminal_surface_t,
    uint32_t,
    double);

// Copies the active selection through the terminal-surface allocator. SENT
// means out contains owned text; CONSUMED_NO_OUTPUT means there is no selection.
// Release a SENT result exactly once with terminal_surface_free_text before
// freeing the owning terminal surface.
GHOSTTY_API ghostty_terminal_surface_input_result_e
ghostty_terminal_surface_read_selection(
    ghostty_terminal_surface_t,
    ghostty_text_s*);
GHOSTTY_API ghostty_terminal_surface_input_result_e
ghostty_terminal_surface_free_text(
    ghostty_terminal_surface_t,
    ghostty_text_s*);

GHOSTTY_API ghostty_config_t ghostty_config_new();
GHOSTTY_API void ghostty_config_free(ghostty_config_t);
GHOSTTY_API ghostty_config_t ghostty_config_clone(ghostty_config_t);
GHOSTTY_API void ghostty_config_load_cli_args(ghostty_config_t);
GHOSTTY_API void ghostty_config_load_file(ghostty_config_t, const char*);
GHOSTTY_API void ghostty_config_load_default_files(ghostty_config_t);
GHOSTTY_API void ghostty_config_load_recursive_files(ghostty_config_t);
GHOSTTY_API void ghostty_config_finalize(ghostty_config_t);
GHOSTTY_API bool ghostty_config_get(ghostty_config_t, void*, const char*, uintptr_t);
GHOSTTY_API ghostty_input_trigger_s ghostty_config_trigger(ghostty_config_t,
                                                              const char*,
                                                              uintptr_t);
GHOSTTY_API bool ghostty_config_key_is_binding(ghostty_config_t, ghostty_input_key_s);
GHOSTTY_API uint32_t ghostty_config_diagnostics_count(ghostty_config_t);
GHOSTTY_API ghostty_diagnostic_s ghostty_config_get_diagnostic(ghostty_config_t, uint32_t);
GHOSTTY_API ghostty_string_s ghostty_config_open_path(void);

GHOSTTY_API ghostty_app_t ghostty_app_new(const ghostty_runtime_config_s*,
                                             ghostty_config_t);
GHOSTTY_API void ghostty_app_free(ghostty_app_t);
GHOSTTY_API void ghostty_app_tick(ghostty_app_t);
GHOSTTY_API void* ghostty_app_userdata(ghostty_app_t);
GHOSTTY_API void ghostty_app_set_focus(ghostty_app_t, bool);
GHOSTTY_API bool ghostty_app_key(ghostty_app_t, ghostty_input_key_s);
GHOSTTY_API void ghostty_app_keyboard_changed(ghostty_app_t);
GHOSTTY_API void ghostty_app_open_config(ghostty_app_t);
GHOSTTY_API void ghostty_app_update_config(ghostty_app_t, ghostty_config_t);
GHOSTTY_API bool ghostty_app_needs_confirm_quit(ghostty_app_t);
GHOSTTY_API bool ghostty_app_has_global_keybinds(ghostty_app_t);
GHOSTTY_API void ghostty_app_set_color_scheme(ghostty_app_t, ghostty_color_scheme_e);

GHOSTTY_API ghostty_surface_config_s ghostty_surface_config_new();

GHOSTTY_API ghostty_surface_t ghostty_surface_new(ghostty_app_t,
                                                     const ghostty_surface_config_s*);
GHOSTTY_API void ghostty_surface_free(ghostty_surface_t);
GHOSTTY_API void* ghostty_surface_userdata(ghostty_surface_t);
GHOSTTY_API ghostty_app_t ghostty_surface_app(ghostty_surface_t);
GHOSTTY_API ghostty_surface_config_s ghostty_surface_inherited_config(ghostty_surface_t, ghostty_surface_context_e);
GHOSTTY_API void ghostty_surface_update_config(ghostty_surface_t, ghostty_config_t);
GHOSTTY_API bool ghostty_surface_needs_confirm_quit(ghostty_surface_t);
GHOSTTY_API bool ghostty_surface_process_exited(ghostty_surface_t);
GHOSTTY_API void ghostty_surface_refresh(ghostty_surface_t);
GHOSTTY_API void ghostty_surface_draw(ghostty_surface_t);
GHOSTTY_API void ghostty_surface_set_content_scale(ghostty_surface_t, double, double);
GHOSTTY_API void ghostty_surface_set_focus(ghostty_surface_t, bool);
GHOSTTY_API void ghostty_surface_set_occlusion(ghostty_surface_t, bool);
GHOSTTY_API void ghostty_surface_set_size(ghostty_surface_t, uint32_t, uint32_t);
GHOSTTY_API ghostty_surface_size_s ghostty_surface_size(ghostty_surface_t);
GHOSTTY_API uint64_t ghostty_surface_foreground_pid(ghostty_surface_t);
GHOSTTY_API ghostty_string_s ghostty_surface_tty_name(ghostty_surface_t);
GHOSTTY_API void ghostty_surface_set_color_scheme(ghostty_surface_t,
                                                     ghostty_color_scheme_e);
GHOSTTY_API ghostty_input_mods_e ghostty_surface_key_translation_mods(ghostty_surface_t,
                                                                         ghostty_input_mods_e);
GHOSTTY_API bool ghostty_surface_key(ghostty_surface_t, ghostty_input_key_s);
GHOSTTY_API bool ghostty_surface_key_is_binding(ghostty_surface_t,
                                                   ghostty_input_key_s,
                                                   ghostty_binding_flags_e*);
GHOSTTY_API void ghostty_surface_text(ghostty_surface_t, const char*, uintptr_t);
GHOSTTY_API void ghostty_surface_preedit(ghostty_surface_t, const char*, uintptr_t);
GHOSTTY_API bool ghostty_surface_mouse_captured(ghostty_surface_t);
GHOSTTY_API bool ghostty_surface_mouse_button(ghostty_surface_t,
                                                 ghostty_input_mouse_state_e,
                                                 ghostty_input_mouse_button_e,
                                                 ghostty_input_mods_e);
GHOSTTY_API void ghostty_surface_mouse_pos(ghostty_surface_t,
                                              double,
                                              double,
                                              ghostty_input_mods_e);
GHOSTTY_API void ghostty_surface_mouse_scroll(ghostty_surface_t,
                                                 double,
                                                 double,
                                                 ghostty_input_scroll_mods_t);
GHOSTTY_API void ghostty_surface_mouse_pressure(ghostty_surface_t, uint32_t, double);
GHOSTTY_API void ghostty_surface_ime_point(ghostty_surface_t, double*, double*, double*, double*);
GHOSTTY_API void ghostty_surface_request_close(ghostty_surface_t);
GHOSTTY_API void ghostty_surface_split(ghostty_surface_t, ghostty_action_split_direction_e);
GHOSTTY_API void ghostty_surface_split_focus(ghostty_surface_t,
                                                ghostty_action_goto_split_e);
GHOSTTY_API void ghostty_surface_split_resize(ghostty_surface_t,
                                                 ghostty_action_resize_split_direction_e,
                                                 uint16_t);
GHOSTTY_API void ghostty_surface_split_equalize(ghostty_surface_t);
GHOSTTY_API bool ghostty_surface_binding_action(ghostty_surface_t, const char*, uintptr_t);
GHOSTTY_API void ghostty_surface_complete_clipboard_request(ghostty_surface_t,
                                                               const char*,
                                                               void*,
                                                               bool);
GHOSTTY_API bool ghostty_surface_has_selection(ghostty_surface_t);
GHOSTTY_API bool ghostty_surface_read_selection(ghostty_surface_t, ghostty_text_s*);
GHOSTTY_API bool ghostty_surface_read_text(ghostty_surface_t,
                                              ghostty_selection_s,
                                              ghostty_text_s*);
GHOSTTY_API void ghostty_surface_free_text(ghostty_surface_t, ghostty_text_s*);

#ifdef __APPLE__
GHOSTTY_API void ghostty_surface_set_display_id(ghostty_surface_t, uint32_t);
GHOSTTY_API void* ghostty_surface_quicklook_font(ghostty_surface_t);
GHOSTTY_API bool ghostty_surface_quicklook_word(ghostty_surface_t, ghostty_text_s*);
#endif

GHOSTTY_API ghostty_inspector_t ghostty_surface_inspector(ghostty_surface_t);
GHOSTTY_API void ghostty_inspector_free(ghostty_surface_t);
GHOSTTY_API void ghostty_inspector_set_focus(ghostty_inspector_t, bool);
GHOSTTY_API void ghostty_inspector_set_content_scale(ghostty_inspector_t, double, double);
GHOSTTY_API void ghostty_inspector_set_size(ghostty_inspector_t, uint32_t, uint32_t);
GHOSTTY_API void ghostty_inspector_mouse_button(ghostty_inspector_t,
                                                   ghostty_input_mouse_state_e,
                                                   ghostty_input_mouse_button_e,
                                                   ghostty_input_mods_e);
GHOSTTY_API void ghostty_inspector_mouse_pos(ghostty_inspector_t, double, double);
GHOSTTY_API void ghostty_inspector_mouse_scroll(ghostty_inspector_t,
                                                   double,
                                                   double,
                                                   ghostty_input_scroll_mods_t);
GHOSTTY_API void ghostty_inspector_key(ghostty_inspector_t,
                                          ghostty_input_action_e,
                                          ghostty_input_key_e,
                                          ghostty_input_mods_e);
GHOSTTY_API void ghostty_inspector_text(ghostty_inspector_t, const char*);

#ifdef __APPLE__
GHOSTTY_API bool ghostty_inspector_metal_init(ghostty_inspector_t, void*);
GHOSTTY_API void ghostty_inspector_metal_render(ghostty_inspector_t, void*, void*);
GHOSTTY_API bool ghostty_inspector_metal_shutdown(ghostty_inspector_t);
#endif

// APIs I'd like to get rid of eventually but are still needed for now.
// Don't use these unless you know what you're doing.
GHOSTTY_API void ghostty_set_window_background_blur(ghostty_app_t, void*);

// Benchmark API, if available.
GHOSTTY_API bool ghostty_benchmark_cli(const char*, const char*);

#ifdef __cplusplus
}
#endif

#endif /* GHOSTTY_H */
