//! wgpu + GLFW platform backend for dvui.
//!
//! Uses raw GLFW C bindings (translate-c) rather than a high-level wrapper.
//! Integrates with an existing GLFW window — does NOT create its own window.
//! Rendering is delegated to the wgpu render backend.

const std = @import("std");
const dvui = @import("dvui");
const glfw = @import("zglfw");

pub const kind: dvui.enums.Backend = .wgpu_glfw;

const log = std.log.scoped(.wgpu_glfw_backend);

const MAX_EVENT_BUFFER_SIZE = 512;

var events: ?std.ArrayList(GlfwEvent) = null;

gpa: std.mem.Allocator,
arena: std.heap.ArenaAllocator,

window: *glfw.GLFWwindow,
cursor: ?*glfw.GLFWcursor,

userKeyCallback: glfw.GLFWkeyfun,
userCharCallback: glfw.GLFWcharfun,
userMouseButtonCallback: glfw.GLFWmousebuttonfun,
userCursorPosCallback: glfw.GLFWcursorposfun,
userFramebufferSizeCallback: glfw.GLFWframebuffersizefun,
userScrollCallback: glfw.GLFWscrollfun,

const GlfwEvent = union(enum) {
    key: struct { window: ?*glfw.GLFWwindow, key: c_int, scancode: c_int, action: c_int, mods: c_int },
    char: struct { window: ?*glfw.GLFWwindow, codepoint: c_uint },
    mouse_button: struct { window: ?*glfw.GLFWwindow, button: c_int, action: c_int, mods: c_int },
    cursor_pos: struct { window: ?*glfw.GLFWwindow, xpos: f64, ypos: f64 },
    framebuffer_size: struct { window: ?*glfw.GLFWwindow, width: c_int, height: c_int },
    scroll: struct { window: ?*glfw.GLFWwindow, xoffset: f64, yoffset: f64 },
};

pub fn init(gpa: std.mem.Allocator, window_ptr: *anyopaque) @This() {
    const window: *glfw.GLFWwindow = @ptrCast(window_ptr);

    events = std.ArrayList(GlfwEvent).initCapacity(gpa, MAX_EVENT_BUFFER_SIZE) catch @panic("OOM");

    return .{
        .gpa = gpa,
        .arena = .init(gpa),
        .window = window,
        .cursor = null,
        .userKeyCallback = glfw.glfwSetKeyCallback(window, &glfwKeyCallback),
        .userCharCallback = glfw.glfwSetCharCallback(window, &glfwCharCallback),
        .userMouseButtonCallback = glfw.glfwSetMouseButtonCallback(window, &glfwMouseButtonCallback),
        .userCursorPosCallback = glfw.glfwSetCursorPosCallback(window, &glfwCursorPosCallback),
        .userFramebufferSizeCallback = glfw.glfwSetFramebufferSizeCallback(window, &glfwFramebufferSizeCallback),
        .userScrollCallback = glfw.glfwSetScrollCallback(window, &glfwScrollCallback),
    };
}

pub fn deinit(self: *@This()) void {
    if (self.cursor) |cur| glfw.glfwDestroyCursor(cur);
    self.arena.deinit();
    if (events) |*ev| ev.deinit(self.gpa);
    _ = glfw.glfwSetKeyCallback(self.window, self.userKeyCallback);
    _ = glfw.glfwSetCharCallback(self.window, self.userCharCallback);
    _ = glfw.glfwSetMouseButtonCallback(self.window, self.userMouseButtonCallback);
    _ = glfw.glfwSetCursorPosCallback(self.window, self.userCursorPosCallback);
    _ = glfw.glfwSetFramebufferSizeCallback(self.window, self.userFramebufferSizeCallback);
    _ = glfw.glfwSetScrollCallback(self.window, self.userScrollCallback);
}

pub fn begin(_: *@This(), _: std.mem.Allocator) !void {}

pub fn end(_: *@This()) !void {}

pub fn addAllEvents(_: *@This(), win: *dvui.Window) void {
    if (events) |*ev| {
        for (ev.items) |event| {
            switch (event) {
                .key => |v| handleKeyEvent(win, v.key, v.action, v.mods),
                .char => |v| handleCharEvent(win, v.codepoint),
                .mouse_button => |v| handleMouseButtonEvent(win, v.button, v.action),
                .cursor_pos => |v| handleCursorPosEvent(win, v.xpos, v.ypos),
                .framebuffer_size => {},
                .scroll => |v| handleScrollEvent(win, v.xoffset, v.yoffset),
            }
        }
        ev.clearRetainingCapacity();
    }
}

pub fn pixelSize(self: *@This()) dvui.Size.Physical {
    var w: c_int = 0;
    var h: c_int = 0;
    glfw.glfwGetFramebufferSize(self.window, &w, &h);
    return .{
        .w = @floatFromInt(@max(0, w)),
        .h = @floatFromInt(@max(0, h)),
    };
}

pub fn windowSize(self: *@This()) dvui.Size.Natural {
    var w: c_int = 0;
    var h: c_int = 0;
    glfw.glfwGetWindowSize(self.window, &w, &h);
    return .{
        .w = @floatFromInt(@max(0, w)),
        .h = @floatFromInt(@max(0, h)),
    };
}

pub fn contentScale(self: *@This()) f32 {
    var xscale: f32 = 1.0;
    var yscale: f32 = 1.0;
    glfw.glfwGetWindowContentScale(self.window, &xscale, &yscale);
    return xscale;
}

pub fn clipboardText(self: *@This()) ![]const u8 {
    _ = self;
    const text = glfw.glfwGetClipboardString(null);
    if (text == null) return "";
    return std.mem.span(text.?);
}

pub fn clipboardTextSet(self: *@This(), text: []const u8) !void {
    const textZ = try self.gpa.dupeZ(u8, text);
    defer self.gpa.free(textZ);
    glfw.glfwSetClipboardString(null, textZ);
}

pub fn openURL(_: *@This(), _: []const u8, _: bool) !void {}

pub fn setCursor(self: *@This(), cursor: dvui.enums.Cursor) void {
    if (cursor == .hidden) {
        glfw.glfwSetInputMode(self.window, glfw.GLFW_CURSOR, glfw.GLFW_CURSOR_HIDDEN);
        return;
    }
    glfw.glfwSetInputMode(self.window, glfw.GLFW_CURSOR, glfw.GLFW_CURSOR_NORMAL);

    if (self.cursor) |cur| glfw.glfwDestroyCursor(cur);
    const shape: c_int = switch (cursor) {
        .arrow => glfw.GLFW_ARROW_CURSOR,
        .arrow_all => glfw.GLFW_RESIZE_ALL_CURSOR,
        .arrow_n_s => glfw.GLFW_RESIZE_NS_CURSOR,
        .arrow_ne_sw => glfw.GLFW_RESIZE_NESW_CURSOR,
        .arrow_nw_se => glfw.GLFW_RESIZE_NWSE_CURSOR,
        .arrow_w_e => glfw.GLFW_RESIZE_EW_CURSOR,
        .bad => glfw.GLFW_NOT_ALLOWED_CURSOR,
        .crosshair => glfw.GLFW_CROSSHAIR_CURSOR,
        .hand => glfw.GLFW_POINTING_HAND_CURSOR,
        .ibeam => glfw.GLFW_IBEAM_CURSOR,
        .wait => glfw.GLFW_ARROW_CURSOR,
        .hidden => unreachable,
    };
    self.cursor = glfw.glfwCreateStandardCursor(shape);
    if (self.cursor) |cur| glfw.glfwSetCursor(self.window, cur);
}

pub fn preferredColorScheme(_: *@This()) ?dvui.enums.ColorScheme {
    return null;
}

pub fn prefersReducedMotion(_: *@This()) bool {
    return false;
}

pub fn nanoTime(_: *@This()) i128 {
    const freq: i128 = @intCast(glfw.glfwGetTimerFrequency());
    const value: i128 = @intCast(glfw.glfwGetTimerValue());
    return @divFloor(value * 1_000_000_000, freq);
}

pub fn sleep(_: *@This(), ns: u64) void {
    // Zig 0.17: std.time.sleep removed. Use GLFW wait with timeout.
    const seconds = @as(f64, @floatFromInt(ns)) / 1_000_000_000.0;
    glfw.glfwWaitEventsTimeout(seconds);
}

pub fn refresh(_: *@This()) void {
    glfw.glfwPostEmptyEvent();
}

// --- GLFW event callbacks (raw C ABI) ---

fn glfwKeyCallback(window: ?*glfw.GLFWwindow, key: c_int, scancode: c_int, action: c_int, mods: c_int) callconv(.c) void {
    if (events) |*ev| {
        if (ev.items.len >= MAX_EVENT_BUFFER_SIZE) return;
        ev.appendAssumeCapacity(.{ .key = .{ .window = window, .key = key, .scancode = scancode, .action = action, .mods = mods } });
    }
}

fn glfwCharCallback(window: ?*glfw.GLFWwindow, codepoint: c_uint) callconv(.c) void {
    if (events) |*ev| {
        if (ev.items.len >= MAX_EVENT_BUFFER_SIZE) return;
        ev.appendAssumeCapacity(.{ .char = .{ .window = window, .codepoint = codepoint } });
    }
}

fn glfwMouseButtonCallback(window: ?*glfw.GLFWwindow, button: c_int, action: c_int, mods: c_int) callconv(.c) void {
    if (events) |*ev| {
        if (ev.items.len >= MAX_EVENT_BUFFER_SIZE) return;
        ev.appendAssumeCapacity(.{ .mouse_button = .{ .window = window, .button = button, .action = action, .mods = mods } });
    }
}

fn glfwCursorPosCallback(window: ?*glfw.GLFWwindow, xpos: f64, ypos: f64) callconv(.c) void {
    if (events) |*ev| {
        if (ev.items.len >= MAX_EVENT_BUFFER_SIZE) return;
        ev.appendAssumeCapacity(.{ .cursor_pos = .{ .window = window, .xpos = xpos, .ypos = ypos } });
    }
}

fn glfwFramebufferSizeCallback(window: ?*glfw.GLFWwindow, width: c_int, height: c_int) callconv(.c) void {
    if (events) |*ev| {
        if (ev.items.len >= MAX_EVENT_BUFFER_SIZE) return;
        ev.appendAssumeCapacity(.{ .framebuffer_size = .{ .window = window, .width = width, .height = height } });
    }
}

fn glfwScrollCallback(window: ?*glfw.GLFWwindow, xoffset: f64, yoffset: f64) callconv(.c) void {
    if (events) |*ev| {
        if (ev.items.len >= MAX_EVENT_BUFFER_SIZE) return;
        ev.appendAssumeCapacity(.{ .scroll = .{ .window = window, .xoffset = xoffset, .yoffset = yoffset } });
    }
}

// --- Event handlers ---

fn handleKeyEvent(dvui_window: *dvui.Window, key: c_int, action: c_int, mods: c_int) void {
    const dvui_action: @FieldType(dvui.Event.Key, "action") = switch (action) {
        glfw.GLFW_PRESS => .down,
        glfw.GLFW_RELEASE => .up,
        glfw.GLFW_REPEAT => .repeat,
        else => return,
    };
    const dvui_key = glfwKeyToDvui(key);
    const dvui_mod = blk: {
        const Mod = dvui.enums.Mod;
        var mod = Mod.none;
        if (mods & glfw.GLFW_MOD_SHIFT != 0) mod.combine(.lshift);
        if (mods & glfw.GLFW_MOD_ALT != 0) mod.combine(.lalt);
        if (mods & glfw.GLFW_MOD_CONTROL != 0) mod.combine(.lcontrol);
        if (mods & glfw.GLFW_MOD_SUPER != 0) mod.combine(.lcommand);
        break :blk mod;
    };
    _ = dvui_window.addEventKey(.{ .action = dvui_action, .code = dvui_key, .mod = dvui_mod }) catch {};
}

fn handleCharEvent(dvui_window: *dvui.Window, codepoint: c_uint) void {
    var buf: [4]u8 = .{ 0, 0, 0, 0 };
    const len = std.unicode.utf8Encode(@intCast(codepoint), &buf) catch return;
    _ = dvui_window.addEventText(.{ .text = buf[0..len] }) catch {};
}

fn handleCursorPosEvent(dvui_window: *dvui.Window, xpos: f64, ypos: f64) void {
    const physical: dvui.Point.Physical = .{
        .x = @floatCast(xpos),
        .y = @floatCast(ypos),
    };
    _ = dvui_window.addEventMouseMotion(.{ .pt = physical }) catch {};
}

fn handleMouseButtonEvent(dvui_window: *dvui.Window, button: c_int, action: c_int) void {
    const dvui_button: dvui.enums.Button = switch (button) {
        glfw.GLFW_MOUSE_BUTTON_LEFT => .left,
        glfw.GLFW_MOUSE_BUTTON_RIGHT => .right,
        glfw.GLFW_MOUSE_BUTTON_MIDDLE => .middle,
        else => return,
    };
    const dvui_action: dvui.Event.Mouse.Action = switch (action) {
        glfw.GLFW_PRESS => .press,
        glfw.GLFW_RELEASE => .release,
        else => return,
    };
    _ = dvui_window.addEventMouseButton(dvui_button, dvui_action) catch {};
}

fn handleScrollEvent(dvui_window: *dvui.Window, xoffset: f64, yoffset: f64) void {
    const scrollx: f32 = @floatCast(xoffset * dvui.scroll_speed);
    const scrolly: f32 = @floatCast(yoffset * dvui.scroll_speed);
    _ = dvui_window.addEventMouseWheel(scrollx, .horizontal) catch {};
    _ = dvui_window.addEventMouseWheel(scrolly, .vertical) catch {};
}

// --- Key code mapping ---

fn glfwKeyToDvui(key: c_int) dvui.enums.Key {
    return switch (key) {
        glfw.GLFW_KEY_A => .a,
        glfw.GLFW_KEY_B => .b,
        glfw.GLFW_KEY_C => .c,
        glfw.GLFW_KEY_D => .d,
        glfw.GLFW_KEY_E => .e,
        glfw.GLFW_KEY_F => .f,
        glfw.GLFW_KEY_G => .g,
        glfw.GLFW_KEY_H => .h,
        glfw.GLFW_KEY_I => .i,
        glfw.GLFW_KEY_J => .j,
        glfw.GLFW_KEY_K => .k,
        glfw.GLFW_KEY_L => .l,
        glfw.GLFW_KEY_M => .m,
        glfw.GLFW_KEY_N => .n,
        glfw.GLFW_KEY_O => .o,
        glfw.GLFW_KEY_P => .p,
        glfw.GLFW_KEY_Q => .q,
        glfw.GLFW_KEY_R => .r,
        glfw.GLFW_KEY_S => .s,
        glfw.GLFW_KEY_T => .t,
        glfw.GLFW_KEY_U => .u,
        glfw.GLFW_KEY_V => .v,
        glfw.GLFW_KEY_W => .w,
        glfw.GLFW_KEY_X => .x,
        glfw.GLFW_KEY_Y => .y,
        glfw.GLFW_KEY_Z => .z,

        glfw.GLFW_KEY_0 => .zero,
        glfw.GLFW_KEY_1 => .one,
        glfw.GLFW_KEY_2 => .two,
        glfw.GLFW_KEY_3 => .three,
        glfw.GLFW_KEY_4 => .four,
        glfw.GLFW_KEY_5 => .five,
        glfw.GLFW_KEY_6 => .six,
        glfw.GLFW_KEY_7 => .seven,
        glfw.GLFW_KEY_8 => .eight,
        glfw.GLFW_KEY_9 => .nine,

        glfw.GLFW_KEY_F1 => .f1,
        glfw.GLFW_KEY_F2 => .f2,
        glfw.GLFW_KEY_F3 => .f3,
        glfw.GLFW_KEY_F4 => .f4,
        glfw.GLFW_KEY_F5 => .f5,
        glfw.GLFW_KEY_F6 => .f6,
        glfw.GLFW_KEY_F7 => .f7,
        glfw.GLFW_KEY_F8 => .f8,
        glfw.GLFW_KEY_F9 => .f9,
        glfw.GLFW_KEY_F10 => .f10,
        glfw.GLFW_KEY_F11 => .f11,
        glfw.GLFW_KEY_F12 => .f12,

        glfw.GLFW_KEY_ENTER => .enter,
        glfw.GLFW_KEY_ESCAPE => .escape,
        glfw.GLFW_KEY_TAB => .tab,
        glfw.GLFW_KEY_LEFT_SHIFT => .left_shift,
        glfw.GLFW_KEY_RIGHT_SHIFT => .right_shift,
        glfw.GLFW_KEY_LEFT_CONTROL => .left_control,
        glfw.GLFW_KEY_RIGHT_CONTROL => .right_control,
        glfw.GLFW_KEY_LEFT_ALT => .left_alt,
        glfw.GLFW_KEY_RIGHT_ALT => .right_alt,
        glfw.GLFW_KEY_LEFT_SUPER => .left_command,
        glfw.GLFW_KEY_RIGHT_SUPER => .right_command,
        glfw.GLFW_KEY_MENU => .menu,
        glfw.GLFW_KEY_NUM_LOCK => .num_lock,
        glfw.GLFW_KEY_CAPS_LOCK => .caps_lock,
        glfw.GLFW_KEY_PRINT_SCREEN => .print,
        glfw.GLFW_KEY_SCROLL_LOCK => .scroll_lock,
        glfw.GLFW_KEY_PAUSE => .pause,
        glfw.GLFW_KEY_DELETE => .delete,
        glfw.GLFW_KEY_HOME => .home,
        glfw.GLFW_KEY_END => .end,
        glfw.GLFW_KEY_PAGE_UP => .page_up,
        glfw.GLFW_KEY_PAGE_DOWN => .page_down,
        glfw.GLFW_KEY_INSERT => .insert,
        glfw.GLFW_KEY_LEFT => .left,
        glfw.GLFW_KEY_RIGHT => .right,
        glfw.GLFW_KEY_UP => .up,
        glfw.GLFW_KEY_DOWN => .down,
        glfw.GLFW_KEY_BACKSPACE => .backspace,
        glfw.GLFW_KEY_SPACE => .space,
        glfw.GLFW_KEY_MINUS => .minus,
        glfw.GLFW_KEY_EQUAL => .equal,
        glfw.GLFW_KEY_LEFT_BRACKET => .left_bracket,
        glfw.GLFW_KEY_RIGHT_BRACKET => .right_bracket,
        glfw.GLFW_KEY_BACKSLASH => .backslash,
        glfw.GLFW_KEY_SEMICOLON => .semicolon,
        glfw.GLFW_KEY_APOSTROPHE => .apostrophe,
        glfw.GLFW_KEY_COMMA => .comma,
        glfw.GLFW_KEY_PERIOD => .period,
        glfw.GLFW_KEY_SLASH => .slash,
        glfw.GLFW_KEY_GRAVE_ACCENT => .grave,

        else => .unknown,
    };
}
