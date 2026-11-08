//! What the JSON viewer remembers about one response: selection, scroll,
//! strings shown whole, and the search. `json_view.zig` draws it.
const std = @import("std");
const model = @import("model.zig");
const Allocator = std.mem.Allocator;

pub const State = struct {
    /// The tree this state belongs to; a new response starts over.
    owner: usize = 0,
    selected: ?u32 = null,
    scroll_y: f32 = 0,
    /// Scroll the selection into view on the next frame.
    reveal: bool = false,
    /// Long strings shown whole, in document order.
    open_strings: std.ArrayList(u32) = .empty,
    find_open: bool = false,
    query: model.TextBuffer = .{},
    case_sensitive: bool = false,
    /// Show only the hits and what contains them.
    filter: bool = false,
    /// The search the tree's hits came from.
    searched: std.ArrayList(u8) = .empty,
    searched_case: bool = false,
    searched_owner: usize = 0,
    /// Which hit is current.
    hit_at: usize = 0,
    /// A malformed JSONPath: where, and what's wrong.
    problem_at: usize = 0,
    problem: []const u8 = "",
    /// The selected node's JSONPath, kept until the selection changes.
    path_of: ?u32 = null,
    path: std.ArrayList(u8) = .empty,
    hover: ?u32 = null,
    hover_since: f64 = 0,
    dragging: bool = false,
    /// Wheel scrolling on its way.
    glide: @import("glide.zig").Glide = .{},
    drag_offset: f32 = 0,

    /// Forgets what belonged to the last response; the search text,
    /// options and whether the search bar is open carry over.
    pub fn reset(s: *State, gpa: Allocator) void {
        s.owner = 0;
        s.selected = null;
        s.scroll_y = 0;
        s.reveal = false;
        s.open_strings.clearAndFree(gpa);
        s.searched.clearAndFree(gpa);
        s.searched_owner = 0;
        s.hit_at = 0;
        s.problem = "";
        s.path_of = null;
        s.path.clearAndFree(gpa);
        s.hover = null;
        s.dragging = false;
        s.glide.stop();
    }

    pub fn deinit(s: *State, gpa: Allocator) void {
        s.reset(gpa);
        s.query.deinit();
    }

    pub fn isOpenString(s: *const State, node: u32) bool {
        return std.sort.binarySearch(u32, s.open_strings.items, node, order) != null;
    }

    /// Shows a long string whole, or shortened again.
    pub fn toggleString(s: *State, gpa: Allocator, node: u32, limit: usize) void {
        const at = std.sort.lowerBound(u32, s.open_strings.items, node, order);
        if (at < s.open_strings.items.len and s.open_strings.items[at] == node) {
            _ = s.open_strings.orderedRemove(at);
        } else if (s.open_strings.items.len < limit) {
            s.open_strings.insert(gpa, at, node) catch {};
        }
    }

    fn order(want: u32, item: u32) std.math.Order {
        return std.math.order(want, item);
    }
};
