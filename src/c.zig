//! Hand-written bindings for the GLib/GIO/GTK4/gtk4-layer-shell calls Lumen
//! makes. Zig 0.16's translate-c cannot digest GLib's headers (`_Pragma`
//! inside macros), so only what is used is declared here; enum values were
//! checked against the installed headers. SQLite still goes through
//! translate-c (see src/sqlite.h).

// ---------------------------------------------------------------- types

pub const gboolean = c_int;
pub const GPid = c_int;
pub const GdkModifierType = c_uint;

pub const GError = extern struct {
    domain: u32,
    code: c_int,
    message: [*:0]u8,
};

pub const GList = extern struct {
    data: ?*anyopaque,
    next: ?*GList,
    prev: ?*GList,
};

pub const GdkRectangle = extern struct { x: c_int, y: c_int, width: c_int, height: c_int };

pub const graphene_rect_t = extern struct {
    origin: extern struct { x: f32, y: f32 },
    size: extern struct { width: f32, height: f32 },
};

pub const GObject = opaque {};
pub const GDir = opaque {};
pub const GDateTime = opaque {};
pub const GIcon = opaque {};
pub const GAppInfo = opaque {};
pub const GDesktopAppInfo = opaque {};
pub const GAppInfoMonitor = opaque {};
pub const GAppLaunchContext = opaque {};
pub const GApplication = opaque {};
pub const GApplicationCommandLine = opaque {};
pub const GListModel = opaque {};
pub const GSubprocess = opaque {};
pub const GOutputStream = opaque {};
pub const GdkDisplay = opaque {};
pub const GdkMonitor = opaque {};
pub const GdkAppLaunchContext = opaque {};
pub const GtkApplication = opaque {};
pub const GtkWidget = opaque {};
pub const GtkWindow = opaque {};
pub const GtkBox = opaque {};
pub const GtkLabel = opaque {};
pub const GtkImage = opaque {};
pub const GtkText = opaque {};
pub const GtkEditable = opaque {};
pub const GtkListBox = opaque {};
pub const GtkListBoxRow = opaque {};
pub const GtkOverlay = opaque {};
pub const GtkScrolledWindow = opaque {};
pub const GtkAdjustment = opaque {};
pub const GtkCssProvider = opaque {};
pub const GSettings = opaque {};
pub const GSettingsSchema = opaque {};
pub const GSettingsSchemaSource = opaque {};
pub const GtkStyleProvider = opaque {};
pub const GtkEventController = opaque {};
pub const GtkEventControllerKey = opaque {};
pub const GtkPicture = opaque {};
pub const GFile = opaque {};
pub const GBytes = opaque {};
pub const GdkTexture = opaque {};

pub const GCallback = *const fn () callconv(.c) void;
pub const GDestroyNotify = *const fn (?*anyopaque) callconv(.c) void;
pub const GSpawnChildSetupFunc = *const fn (?*anyopaque) callconv(.c) void;
pub const GSourceFunc = *const fn (?*anyopaque) callconv(.c) gboolean;

// ------------------------------------------------------------ constants

pub const G_APPLICATION_IS_LAUNCHER: c_int = 1 << 1;
pub const G_APPLICATION_HANDLES_COMMAND_LINE: c_int = 1 << 3;
pub const G_SPAWN_DO_NOT_REAP_CHILD: c_int = 1 << 1;
pub const G_SPAWN_SEARCH_PATH: c_int = 1 << 2;
pub const G_SPAWN_STDERR_TO_DEV_NULL: c_int = 1 << 4;
pub const G_SUBPROCESS_FLAGS_STDIN_PIPE: c_int = 1 << 0;

pub const GDK_SHIFT_MASK: GdkModifierType = 1 << 0;
pub const GDK_CONTROL_MASK: GdkModifierType = 1 << 2;

pub const GDK_KEY_BackSpace: c_uint = 0xff08;
pub const GDK_KEY_Return: c_uint = 0xff0d;
pub const GDK_KEY_Escape: c_uint = 0xff1b;
pub const GDK_KEY_Up: c_uint = 0xff52;
pub const GDK_KEY_Down: c_uint = 0xff54;
pub const GDK_KEY_Page_Up: c_uint = 0xff55;
pub const GDK_KEY_Page_Down: c_uint = 0xff56;
pub const GDK_KEY_KP_Enter: c_uint = 0xff8d;
pub const GDK_KEY_C: c_uint = 0x43;
pub const GDK_KEY_X: c_uint = 0x58;
pub const GDK_KEY_c: c_uint = 0x63;
pub const GDK_KEY_F: c_uint = 0x46;
pub const GDK_KEY_f: c_uint = 0x66;
pub const GDK_KEY_O: c_uint = 0x4f;
pub const GDK_KEY_o: c_uint = 0x6f;
pub const GDK_KEY_j: c_uint = 0x6a;
pub const GDK_KEY_k: c_uint = 0x6b;
pub const GDK_KEY_n: c_uint = 0x6e;
pub const GDK_KEY_p: c_uint = 0x70;
pub const GDK_KEY_x: c_uint = 0x78;

pub const GTK_ALIGN_START: c_int = 1;
pub const GTK_ALIGN_END: c_int = 2;
pub const GTK_ALIGN_CENTER: c_int = 3;
pub const GTK_ORIENTATION_HORIZONTAL: c_int = 0;
pub const GTK_ORIENTATION_VERTICAL: c_int = 1;
pub const GTK_PHASE_CAPTURE: c_int = 1;
pub const GTK_POLICY_AUTOMATIC: c_int = 1;
pub const GTK_POLICY_NEVER: c_int = 2;
pub const GTK_SELECTION_SINGLE: c_int = 1;
pub const GTK_STYLE_PROVIDER_PRIORITY_USER: c_uint = 800;

pub const GTK_LAYER_SHELL_LAYER_OVERLAY: c_int = 3;
pub const GTK_LAYER_SHELL_EDGE_TOP: c_int = 2;
pub const GTK_LAYER_SHELL_KEYBOARD_MODE_NONE: c_int = 0;
pub const GTK_LAYER_SHELL_KEYBOARD_MODE_EXCLUSIVE: c_int = 1;

pub const GTK_CONTENT_FIT_SCALE_DOWN: c_int = 3;

pub const PANGO_ELLIPSIZE_NONE: c_int = 0;
pub const PANGO_ELLIPSIZE_START: c_int = 1;
pub const PANGO_ELLIPSIZE_END: c_int = 3;
pub const PANGO_WRAP_WORD_CHAR: c_int = 2;

pub const SIGTERM: c_int = 15;
pub const PR_SET_PDEATHSIG: c_int = 1;

// ------------------------------------------------------------------ libc

pub extern fn kill(pid: c_int, sig: c_int) c_int;
pub extern fn prctl(option: c_int, ...) c_int;
pub extern fn read(fd: c_int, buf: *anyopaque, count: usize) isize;

// ------------------------------------------------------------------ glib

pub extern fn g_free(mem: ?*anyopaque) void;
pub extern fn g_bytes_new_static(data: [*]const u8, size: usize) *GBytes;
pub extern fn g_bytes_unref(bytes: *GBytes) void;
pub extern fn g_strfreev(v: ?*anyopaque) void;
pub extern fn g_error_free(err: *GError) void;
pub extern fn g_get_real_time() i64;
pub extern fn g_get_user_config_dir() [*:0]const u8;
pub extern fn g_get_user_data_dir() [*:0]const u8;
pub extern fn g_get_user_cache_dir() [*:0]const u8;
pub extern fn g_get_home_dir() [*:0]const u8;
pub extern fn g_getenv(name: [*:0]const u8) ?[*:0]const u8;
pub extern fn g_markup_escape_text(text: [*]const u8, length: isize) [*:0]u8;
pub extern fn g_filename_to_uri(path: [*:0]const u8, hostname: ?[*:0]const u8, err: ?*?*GError) ?[*:0]u8;
pub extern fn g_build_filename(first: [*:0]const u8, ...) [*:0]u8;
pub extern fn g_mkdir_with_parents(path: [*:0]const u8, mode: c_int) c_int;
pub extern fn g_file_get_contents(path: [*:0]const u8, contents: *[*c]u8, length: ?*usize, err: ?*?*GError) gboolean;
pub extern fn g_file_read_link(path: [*:0]const u8, err: ?*?*GError) ?[*:0]u8;
pub extern fn g_find_program_in_path(program: [*:0]const u8) ?[*:0]u8;
pub extern fn g_dir_open(path: [*:0]const u8, flags: c_uint, err: ?*?*GError) ?*GDir;
pub extern fn g_dir_read_name(dir: *GDir) ?[*:0]const u8;
pub extern fn g_dir_close(dir: *GDir) void;
pub extern fn g_list_free_full(list: *GList, free_func: GDestroyNotify) void;
pub extern fn g_list_append(list: ?*GList, data: ?*anyopaque) *GList;
pub extern fn g_list_free(list: *GList) void;
pub extern fn g_bytes_new(data: ?*const anyopaque, size: usize) *GBytes;
pub const GChildWatchFunc = *const fn (GPid, c_int, ?*anyopaque) callconv(.c) void;
pub extern fn g_child_watch_add(pid: GPid, func: GChildWatchFunc, data: ?*anyopaque) c_uint;
pub extern fn g_spawn_close_pid(pid: GPid) void;
pub extern fn g_idle_add(func: GSourceFunc, data: ?*anyopaque) c_uint;
pub extern fn g_timeout_add_seconds(interval: c_uint, func: GSourceFunc, data: ?*anyopaque) c_uint;
pub extern fn g_timeout_add(interval: c_uint, func: GSourceFunc, data: ?*anyopaque) c_uint;

pub extern fn g_spawn_async(working_directory: ?[*:0]const u8, argv: [*]const ?[*:0]const u8, envp: ?[*]const ?[*:0]const u8, flags: c_int, child_setup: ?GSpawnChildSetupFunc, user_data: ?*anyopaque, child_pid: ?*GPid, err: ?*?*GError) gboolean;
pub extern fn g_spawn_sync(working_directory: ?[*:0]const u8, argv: [*]const ?[*:0]const u8, envp: ?[*]const ?[*:0]const u8, flags: c_int, child_setup: ?GSpawnChildSetupFunc, user_data: ?*anyopaque, standard_output: ?*[*c]u8, standard_error: ?*[*c]u8, wait_status: ?*c_int, err: ?*?*GError) gboolean;

pub extern fn g_date_time_new_now_local() *GDateTime;
pub extern fn g_date_time_new_local(year: c_int, month: c_int, day: c_int, hour: c_int, minute: c_int, seconds: f64) *GDateTime;
pub extern fn g_date_time_new_from_unix_local(t: i64) ?*GDateTime;
pub extern fn g_date_time_unref(dt: *GDateTime) void;
pub extern fn g_date_time_get_year(dt: *GDateTime) c_int;
pub extern fn g_date_time_get_month(dt: *GDateTime) c_int;
pub extern fn g_date_time_get_day_of_month(dt: *GDateTime) c_int;
pub extern fn g_date_time_to_unix(dt: *GDateTime) i64;
pub extern fn g_date_time_format(dt: *GDateTime, format: [*:0]const u8) ?[*:0]u8;

// --------------------------------------------------------------- gobject

pub extern fn g_object_unref(obj: ?*anyopaque) void;
pub extern fn g_object_set_data(obj: *anyopaque, key: [*:0]const u8, data: ?*anyopaque) void;
pub extern fn g_object_get_data(obj: *anyopaque, key: [*:0]const u8) ?*anyopaque;
pub extern fn g_signal_connect_data(instance: *anyopaque, signal: [*:0]const u8, handler: GCallback, data: ?*anyopaque, destroy: ?*anyopaque, flags: c_int) c_ulong;

// ------------------------------------------------------------------- gio

pub extern fn g_app_info_get_all() ?*GList;
pub extern fn g_app_info_get_all_for_type(content_type: [*:0]const u8) ?*GList;
pub extern fn g_app_info_get_default_for_type(content_type: [*:0]const u8, must_support_uris: gboolean) ?*GAppInfo;
pub extern fn g_app_info_launch_uris(info: *GAppInfo, uris: ?*GList, ctx: ?*GAppLaunchContext, err: ?*?*GError) gboolean;
pub extern fn g_desktop_app_info_new(desktop_id: [*:0]const u8) ?*GDesktopAppInfo;
pub extern fn g_settings_schema_source_get_default() ?*GSettingsSchemaSource;
pub extern fn g_settings_schema_source_lookup(source: *GSettingsSchemaSource, schema_id: [*:0]const u8, recursive: gboolean) ?*GSettingsSchema;
pub extern fn g_settings_schema_has_key(schema: *GSettingsSchema, name: [*:0]const u8) gboolean;
pub extern fn g_settings_schema_unref(schema: *GSettingsSchema) void;
pub extern fn g_settings_new(schema_id: [*:0]const u8) *GSettings;
pub extern fn g_settings_get_string(settings: *GSettings, key: [*:0]const u8) [*:0]u8;
pub extern fn g_app_info_should_show(info: *GAppInfo) gboolean;
pub extern fn g_app_info_get_id(info: *GAppInfo) ?[*:0]const u8;
pub extern fn g_app_info_get_display_name(info: *GAppInfo) ?[*:0]const u8;
pub extern fn g_app_info_get_executable(info: *GAppInfo) ?[*:0]const u8;
pub extern fn g_app_info_get_icon(info: *GAppInfo) ?*GIcon;
pub extern fn g_app_info_launch(info: *GAppInfo, files: ?*GList, context: ?*GAppLaunchContext, err: ?*?*GError) gboolean;
pub extern fn g_app_info_monitor_get() *GAppInfoMonitor;
pub extern fn g_app_info_launch_default_for_uri(uri: [*:0]const u8, context: ?*GAppLaunchContext, err: ?*?*GError) gboolean;
pub extern fn g_content_type_guess(filename: ?[*:0]const u8, data: ?[*]const u8, size: usize, uncertain: ?*gboolean) ?[*:0]u8;
pub extern fn g_content_type_get_icon(content_type: [*:0]const u8) *GIcon;
pub extern fn g_content_type_get_description(content_type: [*:0]const u8) ?[*:0]u8;
pub extern fn g_content_type_is_a(content_type: [*:0]const u8, supertype: [*:0]const u8) gboolean;
pub extern fn g_file_new_for_path(path: [*:0]const u8) *GFile;
pub extern fn g_file_trash(file: *GFile, cancellable: ?*anyopaque, err: ?*?*GError) gboolean;
pub extern fn g_desktop_app_info_get_generic_name(info: *GDesktopAppInfo) ?[*:0]const u8;
pub extern fn g_desktop_app_info_get_keywords(info: *GDesktopAppInfo) ?[*]const ?[*:0]const u8;
pub extern fn g_desktop_app_info_get_startup_wm_class(info: *GDesktopAppInfo) ?[*:0]const u8;
pub extern fn g_desktop_app_info_get_filename(info: *GDesktopAppInfo) ?[*:0]const u8;

pub extern fn g_application_run(app: *GApplication, argc: c_int, argv: ?[*]?[*:0]u8) c_int;
pub extern fn g_application_hold(app: *GApplication) void;
pub extern fn g_application_register(app: *GApplication, cancellable: ?*anyopaque, err: ?*?*GError) gboolean;
pub extern fn g_application_get_is_remote(app: *GApplication) gboolean;
pub extern fn g_application_quit(app: *GApplication) void;
pub extern fn g_application_command_line_get_arguments(cmdline: *GApplicationCommandLine, argc: *c_int) [*][*:0]u8;
pub extern fn g_application_command_line_print(cmdline: *GApplicationCommandLine, format: [*:0]const u8, ...) void;
pub extern fn g_application_command_line_printerr(cmdline: *GApplicationCommandLine, format: [*:0]const u8, ...) void;

pub extern fn g_list_model_get_n_items(list: *GListModel) c_uint;
pub extern fn g_list_model_get_item(list: *GListModel, position: c_uint) ?*anyopaque;

pub extern fn g_subprocess_newv(argv: [*]const ?[*:0]const u8, flags: c_int, err: ?*?*GError) ?*GSubprocess;
pub extern fn g_subprocess_get_stdin_pipe(sp: *GSubprocess) *GOutputStream;
pub extern fn g_output_stream_write_all(stream: *GOutputStream, buffer: *const anyopaque, count: usize, written: ?*usize, cancellable: ?*anyopaque, err: ?*?*GError) gboolean;
pub extern fn g_output_stream_close(stream: *GOutputStream, cancellable: ?*anyopaque, err: ?*?*GError) gboolean;

// ------------------------------------------------------------------- gdk

pub extern fn gdk_display_get_default() *GdkDisplay;
pub const GDK_MEMORY_R8G8B8A8: c_int = 5;
pub extern fn gdk_memory_texture_new(width: c_int, height: c_int, format: c_int, bytes: *GBytes, stride: usize) *GdkTexture;
pub extern fn gdk_texture_new_from_bytes(bytes: *GBytes, err: ?*?*GError) ?*GdkTexture;
pub extern fn gdk_display_get_monitors(display: *GdkDisplay) *GListModel;
pub extern fn gdk_display_get_app_launch_context(display: *GdkDisplay) *GdkAppLaunchContext;
pub extern fn gdk_monitor_get_connector(monitor: *GdkMonitor) ?[*:0]const u8;
pub extern fn gdk_monitor_get_geometry(monitor: *GdkMonitor, geometry: *GdkRectangle) void;

// ------------------------------------------------------------------- gtk

pub extern fn gtk_application_new(id: [*:0]const u8, flags: c_int) *GtkApplication;
pub extern fn gtk_application_window_new(app: *GtkApplication) *GtkWidget;

pub extern fn gtk_window_set_title(w: *GtkWindow, title: [*:0]const u8) void;
pub extern fn gtk_window_set_resizable(w: *GtkWindow, v: gboolean) void;
pub extern fn gtk_window_set_decorated(w: *GtkWindow, v: gboolean) void;
pub extern fn gtk_window_set_default_size(w: *GtkWindow, width: c_int, height: c_int) void;
pub extern fn gtk_window_set_child(w: *GtkWindow, child: *GtkWidget) void;
pub extern fn gtk_window_present(w: *GtkWindow) void;

pub extern fn gtk_widget_set_visible(w: *GtkWidget, v: gboolean) void;
pub extern fn gtk_widget_get_visible(w: *GtkWidget) gboolean;
pub extern fn gtk_widget_grab_focus(w: *GtkWidget) gboolean;
pub extern fn gtk_widget_add_css_class(w: *GtkWidget, cls: [*:0]const u8) void;
pub extern fn gtk_widget_remove_css_class(w: *GtkWidget, cls: [*:0]const u8) void;
pub extern fn gtk_widget_set_hexpand(w: *GtkWidget, v: gboolean) void;
pub extern fn gtk_widget_set_vexpand(w: *GtkWidget, v: gboolean) void;
pub extern fn gtk_widget_set_halign(w: *GtkWidget, a: c_int) void;
pub extern fn gtk_widget_set_valign(w: *GtkWidget, a: c_int) void;
pub extern fn gtk_widget_set_size_request(w: *GtkWidget, width: c_int, height: c_int) void;
pub extern fn gtk_widget_set_margin_top(w: *GtkWidget, m: c_int) void;
pub extern fn gtk_widget_set_margin_bottom(w: *GtkWidget, m: c_int) void;
pub extern fn gtk_widget_set_margin_start(w: *GtkWidget, m: c_int) void;
pub extern fn gtk_widget_set_margin_end(w: *GtkWidget, m: c_int) void;
pub extern fn gtk_widget_set_focusable(w: *GtkWidget, v: gboolean) void;
pub extern fn gtk_widget_get_frame_clock(w: *GtkWidget) ?*anyopaque;
pub extern fn gtk_widget_add_controller(w: *GtkWidget, controller: *GtkEventController) void;
pub extern fn gtk_widget_compute_bounds(w: *GtkWidget, target: *GtkWidget, out: *graphene_rect_t) gboolean;

pub extern fn gtk_box_new(orientation: c_int, spacing: c_int) *GtkWidget;
pub extern fn gtk_box_append(box: *GtkBox, child: *GtkWidget) void;
pub extern fn gtk_box_set_homogeneous(box: *GtkBox, v: gboolean) void;
pub extern fn gtk_separator_new(orientation: c_int) *GtkWidget;
pub extern fn gtk_overlay_new() *GtkWidget;
pub extern fn gtk_overlay_set_child(o: *GtkOverlay, child: *GtkWidget) void;
pub extern fn gtk_overlay_add_overlay(o: *GtkOverlay, w: *GtkWidget) void;

pub extern fn gtk_label_new(text: ?[*:0]const u8) *GtkWidget;
pub extern fn gtk_label_set_text(l: *GtkLabel, text: [*:0]const u8) void;
pub extern fn gtk_label_get_text(l: *GtkLabel) [*:0]const u8;
pub extern fn gtk_label_set_markup(l: *GtkLabel, markup: [*:0]const u8) void;
pub extern fn gtk_label_set_xalign(l: *GtkLabel, x: f32) void;
pub extern fn gtk_label_set_yalign(l: *GtkLabel, y: f32) void;
pub extern fn gtk_label_set_ellipsize(l: *GtkLabel, mode: c_int) void;
pub extern fn gtk_label_set_max_width_chars(l: *GtkLabel, n: c_int) void;
pub extern fn gtk_label_set_wrap(l: *GtkLabel, v: gboolean) void;
pub extern fn gtk_label_set_wrap_mode(l: *GtkLabel, mode: c_int) void;

pub extern fn gtk_image_new_from_icon_name(name: ?[*:0]const u8) *GtkWidget;
pub extern fn gtk_image_new_from_gicon(icon: *GIcon) *GtkWidget;
pub extern fn gtk_image_new_from_paintable(paintable: ?*anyopaque) *GtkWidget;
pub extern fn gtk_image_set_from_icon_name(img: *GtkImage, name: ?[*:0]const u8) void;
pub extern fn gtk_image_set_pixel_size(img: *GtkImage, size: c_int) void;

pub extern fn gtk_picture_new() *GtkWidget;
pub extern fn gtk_picture_set_filename(p: *GtkPicture, filename: ?[*:0]const u8) void;
pub extern fn gtk_picture_set_content_fit(p: *GtkPicture, fit: c_int) void;

pub extern fn gtk_text_new() *GtkWidget;
pub extern fn gtk_text_set_placeholder_text(t: *GtkText, text: ?[*:0]const u8) void;
pub extern fn gtk_editable_get_text(e: *GtkEditable) [*:0]const u8;
pub extern fn gtk_editable_set_position(e: *GtkEditable, position: c_int) void;
pub extern fn gtk_editable_set_text(e: *GtkEditable, text: [*:0]const u8) void;

pub extern fn gtk_list_box_new() *GtkWidget;
pub extern fn gtk_list_box_append(box: *GtkListBox, child: *GtkWidget) void;
pub extern fn gtk_list_box_remove_all(box: *GtkListBox) void;
pub extern fn gtk_list_box_select_row(box: *GtkListBox, row: ?*GtkListBoxRow) void;
pub extern fn gtk_list_box_unselect_all(box: *GtkListBox) void;
pub extern fn gtk_list_box_set_selection_mode(box: *GtkListBox, mode: c_int) void;
pub extern fn gtk_list_box_get_row_at_index(box: *GtkListBox, index: c_int) ?*GtkListBoxRow;
pub extern fn gtk_list_box_row_new() *GtkWidget;
pub extern fn gtk_list_box_row_set_child(row: *GtkListBoxRow, child: *GtkWidget) void;
pub extern fn gtk_list_box_row_set_selectable(row: *GtkListBoxRow, v: gboolean) void;
pub extern fn gtk_list_box_row_set_activatable(row: *GtkListBoxRow, v: gboolean) void;
pub extern fn gtk_list_box_row_get_index(row: *GtkListBoxRow) c_int;

pub extern fn gtk_scrolled_window_new() *GtkWidget;
pub extern fn gtk_scrolled_window_set_child(sw: *GtkScrolledWindow, child: *GtkWidget) void;
pub extern fn gtk_scrolled_window_set_policy(sw: *GtkScrolledWindow, h: c_int, v: c_int) void;
pub extern fn gtk_scrolled_window_set_propagate_natural_height(sw: *GtkScrolledWindow, propagate: gboolean) void;
pub extern fn gtk_scrolled_window_set_max_content_height(sw: *GtkScrolledWindow, height: c_int) void;
pub extern fn gtk_scrolled_window_get_vadjustment(sw: *GtkScrolledWindow) *GtkAdjustment;
pub extern fn gtk_adjustment_get_value(adj: *GtkAdjustment) f64;
pub extern fn gtk_adjustment_set_value(adj: *GtkAdjustment, v: f64) void;
pub extern fn gtk_adjustment_get_page_size(adj: *GtkAdjustment) f64;

pub extern fn gtk_css_provider_new() *GtkCssProvider;
pub extern fn gtk_css_provider_load_from_string(p: *GtkCssProvider, css: [*:0]const u8) void;
pub extern fn gtk_style_context_add_provider_for_display(display: *GdkDisplay, provider: *GtkStyleProvider, priority: c_uint) void;

pub extern fn gtk_event_controller_key_new() *GtkEventController;
pub extern fn gtk_gesture_click_new() *GtkEventController;
pub extern fn gtk_widget_set_cursor_from_name(w: *GtkWidget, name: ?[*:0]const u8) void;
pub extern fn gtk_widget_set_tooltip_text(w: *GtkWidget, text: ?[*:0]const u8) void;
pub extern fn gtk_event_controller_set_propagation_phase(c: *GtkEventController, phase: c_int) void;

// ------------------------------------------------------- gtk4-layer-shell

pub extern fn gtk_layer_init_for_window(w: *GtkWindow) void;
pub extern fn gtk_layer_set_layer(w: *GtkWindow, layer: c_int) void;
pub extern fn gtk_layer_set_keyboard_mode(w: *GtkWindow, mode: c_int) void;
pub extern fn gtk_layer_set_namespace(w: *GtkWindow, ns: [*:0]const u8) void;
pub extern fn gtk_layer_set_anchor(w: *GtkWindow, edge: c_int, anchor: gboolean) void;
pub extern fn gtk_layer_set_margin(w: *GtkWindow, edge: c_int, margin: c_int) void;
pub extern fn gtk_layer_set_monitor(w: *GtkWindow, monitor: ?*GdkMonitor) void;
