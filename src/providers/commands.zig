//! Built-in commands: views, system, media and window management.

const Item = @import("../item.zig").Item;

pub const views = [_]Item{
    .{ .key = "cmd:clipboard", .title = "Clipboard History", .subtitle = "Lumen", .accessory = "Command", .keywords = "paste copy history", .icon = .{ .tile = .{ .name = "edit-paste-symbolic", .color = .red } }, .action = .{ .view = .clipboard } },
    .{ .key = "cmd:files", .title = "Search Files", .subtitle = "Lumen", .accessory = "Command", .keywords = "find file folder document", .icon = .{ .tile = .{ .name = "folder-saved-search-symbolic", .color = .orange } }, .action = .{ .view = .files } },
    .{ .key = "cmd:contents", .title = "Search File Contents", .subtitle = "Lumen", .accessory = "Command", .keywords = "grep text find inside code", .icon = .{ .tile = .{ .name = "edit-find-symbolic", .color = .purple } }, .action = .{ .view = .contents } },
    .{ .key = "cmd:settings", .title = "Lumen Settings", .subtitle = "Lumen", .accessory = "Command", .keywords = "preferences configuration options", .icon = .{ .tile = .{ .name = "emblem-system-symbolic", .color = .gray } }, .action = .{ .view = .settings } },
    .{ .key = "cmd:themes", .title = "Change Theme", .subtitle = "Lumen", .accessory = "Command", .keywords = "appearance colors dark light", .icon = .{ .tile = .{ .name = "applications-graphics-symbolic", .color = .purple } }, .action = .{ .view = .themes } },
    .{ .key = "cmd:default_apps", .title = "Default Apps", .subtitle = "Lumen", .accessory = "Command", .keywords = "open with file types associations", .icon = .{ .tile = .{ .name = "applications-system-symbolic", .color = .blue } }, .action = .{ .view = .default_apps } },
    .{ .key = "cmd:windows", .title = "Search Windows", .subtitle = "Lumen", .accessory = "Command", .keywords = "switch focus window", .icon = .{ .tile = .{ .name = "focus-windows-symbolic", .color = .blue } }, .action = .{ .view = .windows } },
};

pub const all = views ++ system ++ media ++ windows;

const system = [_]Item{
    .{ .key = "sys:lock", .title = "Lock Screen", .subtitle = "System", .accessory = "Command", .icon = .{ .tile = .{ .name = "system-lock-screen-symbolic", .color = .gray } }, .action = .{ .system = .lock } },
    .{ .key = "sys:sleep", .title = "Sleep", .subtitle = "System", .accessory = "Command", .keywords = "suspend", .icon = .{ .tile = .{ .name = "weather-clear-night-symbolic", .color = .gray } }, .action = .{ .system = .sleep } },
    .{ .key = "sys:restart", .title = "Restart", .subtitle = "System", .accessory = "Command", .keywords = "reboot", .confirm = true, .icon = .{ .tile = .{ .name = "system-reboot-symbolic", .color = .gray } }, .action = .{ .system = .restart } },
    .{ .key = "sys:shutdown", .title = "Shut Down", .subtitle = "System", .accessory = "Command", .keywords = "power off poweroff", .confirm = true, .icon = .{ .tile = .{ .name = "system-shutdown-symbolic", .color = .red } }, .action = .{ .system = .shutdown } },
    .{ .key = "sys:logout", .title = "Log Out", .subtitle = "System", .accessory = "Command", .keywords = "exit hyprland session", .confirm = true, .icon = .{ .tile = .{ .name = "system-log-out-symbolic", .color = .gray } }, .action = .{ .system = .logout } },
    .{ .key = "sys:dark", .title = "Toggle System Appearance", .subtitle = "System", .accessory = "Command", .keywords = "dark light mode theme", .icon = .{ .tile = .{ .name = "weather-clear-night-symbolic", .color = .purple } }, .action = .{ .system = .toggle_dark } },
    .{ .key = "sys:trash", .title = "Empty Trash", .subtitle = "System", .accessory = "Command", .keywords = "bin delete", .confirm = true, .icon = .{ .tile = .{ .name = "user-trash-symbolic", .color = .gray } }, .action = .{ .system = .empty_trash } },
};

const media = [_]Item{
    .{ .key = "sys:volup", .title = "Volume Up", .subtitle = "Audio", .accessory = "Command", .keywords = "sound louder", .icon = .{ .tile = .{ .name = "audio-volume-high-symbolic", .color = .pink } }, .action = .{ .system = .volume_up } },
    .{ .key = "sys:voldown", .title = "Volume Down", .subtitle = "Audio", .accessory = "Command", .keywords = "sound quieter", .icon = .{ .tile = .{ .name = "audio-volume-low-symbolic", .color = .pink } }, .action = .{ .system = .volume_down } },
    .{ .key = "sys:mute", .title = "Toggle Mute", .subtitle = "Audio", .accessory = "Command", .keywords = "sound silence", .icon = .{ .tile = .{ .name = "audio-volume-muted-symbolic", .color = .pink } }, .action = .{ .system = .volume_mute } },
    .{ .key = "sys:mic", .title = "Toggle Microphone", .subtitle = "Audio", .accessory = "Command", .keywords = "mute mic input", .icon = .{ .tile = .{ .name = "microphone-sensitivity-muted-symbolic", .color = .pink } }, .action = .{ .system = .mic_mute } },
    .{ .key = "sys:play", .title = "Play / Pause", .subtitle = "Media", .accessory = "Command", .keywords = "music player pause resume", .icon = .{ .tile = .{ .name = "media-playback-start-symbolic", .color = .orange } }, .action = .{ .system = .play_pause } },
    .{ .key = "sys:next", .title = "Next Track", .subtitle = "Media", .accessory = "Command", .keywords = "music skip forward", .icon = .{ .tile = .{ .name = "media-skip-forward-symbolic", .color = .orange } }, .action = .{ .system = .next_track } },
    .{ .key = "sys:prev", .title = "Previous Track", .subtitle = "Media", .accessory = "Command", .keywords = "music back", .icon = .{ .tile = .{ .name = "media-skip-backward-symbolic", .color = .orange } }, .action = .{ .system = .prev_track } },
};

const windows = [_]Item{
    .{ .key = "win:left", .title = "Left Half", .subtitle = "Window Management", .accessory = "Command", .keywords = "snap tile", .icon = .{ .tile = .{ .name = "view-dual-symbolic", .color = .green } }, .action = .{ .layout = .left_half } },
    .{ .key = "win:right", .title = "Right Half", .subtitle = "Window Management", .accessory = "Command", .keywords = "snap tile", .icon = .{ .tile = .{ .name = "view-dual-symbolic", .color = .green } }, .action = .{ .layout = .right_half } },
    .{ .key = "win:top", .title = "Top Half", .subtitle = "Window Management", .accessory = "Command", .keywords = "snap tile", .icon = .{ .tile = .{ .name = "view-paged-symbolic", .color = .green } }, .action = .{ .layout = .top_half } },
    .{ .key = "win:bottom", .title = "Bottom Half", .subtitle = "Window Management", .accessory = "Command", .keywords = "snap tile", .icon = .{ .tile = .{ .name = "view-paged-symbolic", .color = .green } }, .action = .{ .layout = .bottom_half } },
    .{ .key = "win:max", .title = "Maximize", .subtitle = "Window Management", .accessory = "Command", .keywords = "fill", .icon = .{ .tile = .{ .name = "window-maximize-symbolic", .color = .green } }, .action = .{ .layout = .maximize } },
    .{ .key = "win:almost", .title = "Almost Maximize", .subtitle = "Window Management", .accessory = "Command", .icon = .{ .tile = .{ .name = "window-restore-symbolic", .color = .green } }, .action = .{ .layout = .almost_maximize } },
    .{ .key = "win:center", .title = "Center", .subtitle = "Window Management", .accessory = "Command", .icon = .{ .tile = .{ .name = "zoom-fit-best-symbolic", .color = .green } }, .action = .{ .layout = .center } },
    .{ .key = "win:third1", .title = "First Third", .subtitle = "Window Management", .accessory = "Command", .icon = .{ .tile = .{ .name = "go-first-symbolic", .color = .green } }, .action = .{ .layout = .first_third } },
    .{ .key = "win:third2", .title = "Center Third", .subtitle = "Window Management", .accessory = "Command", .icon = .{ .tile = .{ .name = "view-continuous-symbolic", .color = .green } }, .action = .{ .layout = .center_third } },
    .{ .key = "win:third3", .title = "Last Third", .subtitle = "Window Management", .accessory = "Command", .icon = .{ .tile = .{ .name = "go-last-symbolic", .color = .green } }, .action = .{ .layout = .last_third } },
    .{ .key = "win:float", .title = "Toggle Floating", .subtitle = "Window Management", .accessory = "Command", .keywords = "tile tiling", .icon = .{ .tile = .{ .name = "window-new-symbolic", .color = .green } }, .action = .{ .window_op = .toggle_floating } },
    .{ .key = "win:full", .title = "Toggle Fullscreen", .subtitle = "Window Management", .accessory = "Command", .icon = .{ .tile = .{ .name = "view-fullscreen-symbolic", .color = .green } }, .action = .{ .window_op = .toggle_fullscreen } },
    .{ .key = "win:pin", .title = "Pin Window", .subtitle = "Window Management", .accessory = "Command", .keywords = "sticky all workspaces", .icon = .{ .tile = .{ .name = "view-restore-symbolic", .color = .green } }, .action = .{ .window_op = .pin } },
    .{ .key = "win:close", .title = "Close Window", .subtitle = "Window Management", .accessory = "Command", .keywords = "kill quit", .icon = .{ .tile = .{ .name = "window-close-symbolic", .color = .green } }, .action = .{ .window_op = .close } },
    .{ .key = "win:nextws", .title = "Next Workspace", .subtitle = "Window Management", .accessory = "Command", .keywords = "desktop", .icon = .{ .tile = .{ .name = "go-next-symbolic", .color = .green } }, .action = .{ .window_op = .next_workspace } },
    .{ .key = "win:prevws", .title = "Previous Workspace", .subtitle = "Window Management", .accessory = "Command", .keywords = "desktop", .icon = .{ .tile = .{ .name = "go-previous-symbolic", .color = .green } }, .action = .{ .window_op = .prev_workspace } },
    .{ .key = "win:nextmon", .title = "Move to Next Display", .subtitle = "Window Management", .accessory = "Command", .keywords = "monitor screen", .icon = .{ .tile = .{ .name = "object-flip-horizontal-symbolic", .color = .green } }, .action = .{ .window_op = .move_next_monitor } },
};
