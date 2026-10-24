//! The rest of a pane's pending escape sequence whose start was dropped.
//!
//! A pane's pending capture (`capture-pane -P`) holds what tmux's input
//! parser has read since it was last in its ground state: the start of an
//! escape sequence the pane's program hasn't finished. When that capture is
//! too large to keep, the program's later output carries on the sequence.
//! `Remainder` reads it by the rules of tmux's parser (input.c), so only what
//! tmux runs inside the sequence runs, and finds where the output after the
//! sequence begins.
//!
//! Only the start of the capture is kept, so the sequence it leaves tmux's
//! parser in is taken to run on through the bytes dropped after it.
//!
//! tmux also gives up a DCS, OSC, APC, SOS, PM or screen title five seconds
//! after it began and shows the rest as text. Like the pane's own parser,
//! `Remainder` reads the sequence until it ends.

const std = @import("std");
const testing = std.testing;

const esc = 0x1b;

pub const Remainder = struct {
    state: State,

    /// The states of tmux's input parser a sequence can be left in. tmux's
    /// four CSI states end a sequence alike and are one state here, as are
    /// the strings that only ESC, CAN or SUB end: APC, SOS, PM and screen's
    /// title (ESC k).
    pub const State = enum {
        escape,
        escape_intermediate,
        csi,
        dcs_entry,
        dcs_parameter,
        dcs_intermediate,
        dcs_ignore,

        /// A DCS's data, which only ESC \ ends.
        dcs_data,

        /// ESC in a DCS's data.
        dcs_data_escape,

        osc,
        string,
    };

    /// What a byte of output is to the sequence.
    pub const Byte = enum {
        /// Part of the sequence, which does nothing.
        skip,

        /// A C0 control, which tmux runs inside an escape or CSI sequence.
        execute,

        /// The sequence's last byte.
        end,

        /// ESC, which starts a new sequence and so ends this one before it.
        escape,
    };

    /// The sequence tmux's parser is left in after `start`, the decoded
    /// start of a pending capture, or null if it's left in none.
    pub fn after(start: []const u8) ?Remainder {
        var remainder: ?Remainder = null;
        for (start) |c| {
            if (remainder) |*r| switch (r.next(c)) {
                .skip, .execute => {},
                .end => remainder = null,
                .escape => r.state = .escape,
            } else if (c == esc) remainder = .{ .state = .escape };
        }
        return remainder;
    }

    /// Read the next byte of output.
    pub fn next(self: *Remainder, c: u8) Byte {
        // Anywhere but in a DCS's data, CAN and SUB cancel a sequence and
        // ESC starts a new one.
        switch (self.state) {
            .dcs_data, .dcs_data_escape => {},
            else => switch (c) {
                0x18, 0x1a => return .end,
                esc => return .escape,
                else => {},
            },
        }

        switch (self.state) {
            .escape => switch (c) {
                0x20...0x2f => self.state = .escape_intermediate,
                '[' => self.state = .csi,
                ']' => self.state = .osc,
                'P' => self.state = .dcs_entry,
                'X', '^', '_', 'k' => self.state = .string,
                0x30...0x4f, 0x51...0x57, 0x59...0x5a, 0x5c, 0x60...0x6a, 0x6c...0x7e => return .end,
                else => return control(c),
            },
            .escape_intermediate => switch (c) {
                0x30...0x7e => return .end,
                else => return control(c),
            },
            .csi => switch (c) {
                0x40...0x7e => return .end,
                else => return control(c),
            },
            .dcs_entry => switch (c) {
                0x20...0x2f => self.state = .dcs_intermediate,
                0x30...0x39, 0x3b...0x3f => self.state = .dcs_parameter,
                0x3a => self.state = .dcs_ignore,
                0x40...0x7e => self.state = .dcs_data,
                else => {},
            },
            .dcs_parameter => switch (c) {
                0x20...0x2f => self.state = .dcs_intermediate,
                0x3a, 0x3c...0x3f => self.state = .dcs_ignore,
                0x40...0x7e => self.state = .dcs_data,
                else => {},
            },
            .dcs_intermediate => switch (c) {
                0x30...0x3f => self.state = .dcs_ignore,
                0x40...0x7e => self.state = .dcs_data,
                else => {},
            },
            .dcs_ignore, .string => {},
            .dcs_data => if (c == esc) {
                self.state = .dcs_data_escape;
            },
            .dcs_data_escape => {
                if (c == '\\') return .end;
                self.state = .dcs_data;
            },
            .osc => if (c == 0x07) return .end,
        }
        return .skip;
    }

    /// A byte of an escape or CSI sequence that neither ends it nor moves it
    /// to another state.
    fn control(c: u8) Byte {
        return if (c < 0x20) .execute else .skip;
    }
};

/// Read `output` past the remainder `start` leaves, and expect what the
/// pane's parser gets: the C0 controls tmux runs inside the sequence, then
/// the output after it.
fn expectRead(start: []const u8, output: []const u8, expected: []const u8) !void {
    var buffer: [64]u8 = undefined;
    var len: usize = 0;
    var remainder = Remainder.after(start).?;
    const rest = for (output, 0..) |c, i| switch (remainder.next(c)) {
        .skip => {},
        .execute => {
            buffer[len] = c;
            len += 1;
        },
        .end => break output[i + 1 ..],
        .escape => break output[i..],
    } else return error.TestUnexpectedResult;
    @memcpy(buffer[len..][0..rest.len], rest);
    try testing.expectEqualStrings(expected, buffer[0 .. len + rest.len]);
}

test "pending CSI ends at its final byte and runs C0 controls" {
    try expectRead("\x1b[1;1;1", "2\r\n;3JX", "\r\nX");
    try expectRead("\x1b[?1", "$ 0\x7f\xc3\xa9pX", "X");
    try expectRead("\x1b[1;1", "2\x1b[0mX", "\x1b[0mX");
    try expectRead("\x1b[1;1", "2\x18X", "X");
}

test "pending escape with intermediates ends at its final byte" {
    try expectRead("\x1b(((", "(\n0X", "\nX");
}

test "pending OSC ends at BEL, ESC, CAN or SUB and ignores C0 controls" {
    try expectRead("\x1b]2;aaaa", "11;rgb:ffff/0000/0000\x07X", "X");
    try expectRead("\x1b]2;aaaa", "2;\r\nT\x1b\\X", "\x1b\\X");
    try expectRead("\x1b]2;aaaa", "\xc3\xa9\x9c\x1aX", "X");
}

test "pending APC, SOS, PM and screen title end only at ESC, CAN or SUB" {
    try expectRead("\x1b_aaaa", "Ga=T\x07;AAAA\x1b\\X", "\x1b\\X");
    try expectRead("\x1bXaaaa", "\x9cGa=T\x1b\\X", "\x1b\\X");
    try expectRead("\x1b^aaaa", "b\x07\x18X", "X");
    try expectRead("\x1bkaaaa", "b\r\nc\x1b\\X", "\x1b\\X");
}

test "pending DCS data ends only at ESC \\" {
    try expectRead("\x1bPtmux;aaaa", "b\x1b\x1b]2;T\x07\x1b[2J\x18\x1a\x1b\x1b\\c\x1b\\X", "X");
    try expectRead("\x1bP0;1q#0", "!9~-#1~~\x1b\\X", "X");
}

test "pending DCS before its data ends as tmux's DCS states do" {
    // The parameters run into data at the final byte.
    try expectRead("\x1bP1;2", "3q\x1b[2J\x1b\\X", "X");
    // A colon, a private marker after a parameter, or a parameter after an
    // intermediate makes it a DCS tmux ignores, which ESC ends.
    try expectRead("\x1bP1", ":q\x1b[2JX", "\x1b[2JX");
    try expectRead("\x1bP1", "?q\x1b[2JX", "\x1b[2JX");
    try expectRead("\x1bP$", "0q\x1b[2JX", "\x1b[2JX");
    // A private marker first is a parameter.
    try expectRead("\x1bP?", "1q\x1b[2J\x1b\\X", "X");
    // C0 controls are ignored and CAN cancels.
    try expectRead("\x1bP1", "\r\n\x18X", "X");
}

test "pending sequence is the one the capture's start leaves unfinished" {
    // ESC starts a new sequence, ending the one before it.
    try testing.expectEqual(Remainder.State.osc, Remainder.after("\x1b[1;2\x1b]2;a").?.state);
    try testing.expectEqual(Remainder.State.csi, Remainder.after("\x1b\x1b[1").?.state);
    try testing.expectEqual(Remainder.State.escape, Remainder.after("\x1b]2;a\x1b").?.state);
    // In a DCS's data, ESC is data unless \ follows it.
    try testing.expectEqual(Remainder.State.dcs_data, Remainder.after("\x1bPq\x1b\x1b").?.state);
    try testing.expectEqual(Remainder.State.dcs_data_escape, Remainder.after("\x1bPq\x1b[\x1b").?.state);
    // A start whose sequences all end leaves none.
    try testing.expect(Remainder.after("\x1b]2;a\x07") == null);
    try testing.expect(Remainder.after("") == null);
    try testing.expect(Remainder.after("abc") == null);
}

test "pending ESC starts the sequence its next byte names" {
    // tmux runs C0 controls after ESC and keeps waiting.
    try expectRead("\x1b", "\n[2JX", "\nX");
    try expectRead("\x1b", "7X", "X");
    try expectRead("\x1b", "]11;rgb:ffff/0000/0000\x07X", "X");
}
