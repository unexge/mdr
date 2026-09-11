//! Zero-copy Mermaid sequence diagram parser.

pub const max_participants = 32;
pub const max_messages = 128;
pub const max_notes = 32;
pub const max_fragments = 16;
pub const max_fragment_depth = 8;
pub const max_activations = 64;
pub const max_participant_boxes = 16;

pub const ParticipantKind = enum {
    participant,
    actor,
    boundary,
    control,
    entity,
    database,
    collections,
    queue,
};

pub const Participant = struct {
    id: []const u8,
    label: []const u8,
    kind: ParticipantKind = .participant,
    created_at: ?usize = null,
    destroyed_at: ?usize = null,
    link: ?[]const u8 = null,
};

pub const ParticipantBox = struct {
    label: []const u8,
    color: ?[]const u8,
    first: usize,
    count: usize,
};

pub const MsgStyle = enum { solid, dotted };
pub const MsgEndpoint = enum { none, arrow, cross, open, half_top, half_bottom, stick_top, stick_bottom };
pub const CentralConnection = enum { none, source, destination, both };

pub const Message = struct {
    src: []const u8,
    dst: []const u8,
    style: MsgStyle,
    src_endpoint: MsgEndpoint,
    dst_endpoint: MsgEndpoint,
    central: CentralConnection,
    number: ?u64,
    text: []const u8,
    pos: usize,
};

pub const NoteKind = enum { over, left, right };

pub const Note = struct {
    kind: NoteKind,
    a: []const u8,
    b: ?[]const u8,
    text: []const u8,
    pos: usize,
};

pub const FragmentOp = enum { loop, alt, opt, par, par_over, critical, @"break", rect };

pub const Divider = struct {
    pos: usize,
    head: []const u8,
    text: []const u8,
};

pub const Fragment = struct {
    op: FragmentOp,
    label: []const u8,
    start: usize,
    end: usize,
    divs: [8]Divider = undefined,
    div_count: usize = 0,
    depth: usize,
};

pub const Activation = struct {
    actor: []const u8,
    start: usize,
    end: usize,
    depth: usize,
};

pub const Autonumber = struct {
    start: u32,
    increment: u32,
};

pub const Sequence = struct {
    title: ?[]const u8 = null,
    participants: [max_participants]Participant = undefined,
    participant_count: usize = 0,
    messages: [max_messages]Message = undefined,
    message_count: usize = 0,
    notes: [max_notes]Note = undefined,
    note_count: usize = 0,
    fragments: [max_fragments]Fragment = undefined,
    fragment_count: usize = 0,
    activations: [max_activations]Activation = undefined,
    activation_count: usize = 0,
    participant_boxes: [max_participant_boxes]ParticipantBox = undefined,
    participant_box_count: usize = 0,
    autonumber: ?Autonumber = null,
    degraded: bool = false,
};

pub fn parseSequenceBlockText(text: []const u8) ?Sequence {
    var parser: SeqParser = .{};
    feedLines(&parser, text);
    if (!parser.seen_header or !parser.supported) return null;
    parser.finish();
    if (!parser.supported) return null;
    return parser.seq;
}

pub fn parseSequenceBlock(cb: Document.Element.CodeBlock) ?Sequence {
    const info = cb.info orelse return null;
    if (!info.isMermaid()) return null;
    var parser: SeqParser = .{};
    var lines = cb.lines();
    while (lines.next()) |line| parser.feed(line);
    if (!parser.seen_header or !parser.supported) return null;
    parser.finish();
    if (!parser.supported) return null;
    return parser.seq;
}

const PendingActivation = struct {
    participant: usize,
    start: usize,
    depth: usize,
};

const PendingLifecycle = union(enum) {
    create: usize,
    destroy: usize,
};

const SeqParser = struct {
    seq: Sequence = .{},
    seen_header: bool = false,
    supported: bool = true,
    pos: usize = 0,
    stack: [max_fragment_depth]usize = undefined,
    stack_len: usize = 0,
    pending_activations: [max_activations]PendingActivation = undefined,
    pending_activation_count: usize = 0,
    open_participant_box: ?usize = null,
    pending_lifecycle: ?PendingLifecycle = null,
    next_sequence_number: u64 = 0,
    reading_accessibility_description: bool = false,
    reading_frontmatter: bool = false,

    fn feed(self: *SeqParser, raw: []const u8) void {
        const raw_trimmed = mem.trim(u8, raw, " \t\r");
        if (isConfigDirective(raw_trimmed)) {
            self.feedStatement(raw_trimmed);
            return;
        }
        const source = stripSequenceComment(raw);
        const trimmed = mem.trim(u8, source, " \t\r");
        if (isComment(trimmed)) {
            self.feedStatement(trimmed);
            return;
        }
        var start: usize = 0;
        var quoted = false;
        var depth: usize = 0;
        var i: usize = 0;
        while (i <= source.len) : (i += 1) {
            const at_end = i == source.len;
            if (!at_end) {
                switch (source[i]) {
                    '"' => quoted = !quoted,
                    '{' => if (!quoted) {
                        depth += 1;
                    },
                    '}' => if (!quoted) {
                        depth -|= 1;
                    },
                    else => {},
                }
            }
            if (!at_end and (source[i] != ';' or quoted or depth > 0 or isEntitySemicolon(source, i))) continue;
            self.feedStatement(source[start..i]);
            if (self.seq.degraded or !self.supported) return;
            start = i + 1;
        }
    }

    fn feedStatement(self: *SeqParser, raw: []const u8) void {
        if (self.seq.degraded or !self.supported) return;
        const line = mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or isComment(line)) return;
        if (mem.eql(u8, line, "---")) {
            self.reading_frontmatter = !self.reading_frontmatter;
            return;
        }
        if (self.reading_frontmatter or isConfigDirective(line)) return;
        if (!self.seen_header) {
            if (!eqlIgnoreCase(line, "sequenceDiagram")) {
                self.supported = false;
                return;
            }
            self.seen_header = true;
            return;
        }
        if (self.reading_accessibility_description) {
            if (mem.indexOfScalar(u8, line, '}') != null) self.reading_accessibility_description = false;
            return;
        }
        if (self.feedMetadata(line)) return;
        if (self.pending_lifecycle != null) {
            const message = parseMessageLine(line) orelse {
                self.supported = false;
                return;
            };
            self.addMessage(message);
            return;
        }
        if (self.open_participant_box != null) {
            if (parseParticipantLine(line)) |participant| {
                const before = self.seq.participant_count;
                _ = self.addParticipant(participant) orelse return;
                if (self.seq.participant_count == before) self.supported = false;
            } else if (stripKeyword(line, "end")) |tail| {
                if (tail.len > 0) self.supported = false else self.closeParticipantBox();
            } else {
                self.supported = false;
            }
            return;
        }
        if (self.feedActorMetadata(line)) return;
        if (self.feedLifecycle(line)) return;
        if (parseParticipantLine(line)) |participant| {
            _ = self.addParticipant(participant);
            return;
        }
        if (parseNoteLine(line)) |n| {
            self.addNote(n.kind, n.a, n.b, n.text);
            return;
        }
        if (self.feedControl(line)) return;
        if (parseMessageLine(line)) |m| {
            self.addMessage(m);
            return;
        }
        self.supported = false;
    }

    fn finish(self: *SeqParser) void {
        if (self.seq.degraded) return;
        if (self.pending_lifecycle != null or self.open_participant_box != null or self.stack_len > 0 or
            self.reading_accessibility_description or self.reading_frontmatter)
        {
            self.supported = false;
            return;
        }
        for (self.pending_activations[0..self.pending_activation_count]) |pending| {
            self.appendActivation(pending, self.pos);
            if (self.seq.degraded) return;
        }
        self.pending_activation_count = 0;
    }

    fn intern(self: *SeqParser, id: []const u8) ?usize {
        for (self.seq.participants[0..self.seq.participant_count], 0..) |*p, i| {
            if (mem.eql(u8, p.id, id)) return i;
        }
        if (self.seq.participant_count >= max_participants) {
            self.seq.degraded = true;
            return null;
        }
        self.seq.participants[self.seq.participant_count] = .{ .id = id, .label = id };
        self.seq.participant_count += 1;
        return self.seq.participant_count - 1;
    }

    fn addParticipant(self: *SeqParser, parsed: ParsedParticipant) ?usize {
        for (self.seq.participants[0..self.seq.participant_count], 0..) |*participant, index| {
            if (!mem.eql(u8, participant.id, parsed.id)) continue;
            if (parsed.label_explicit) participant.label = parsed.label;
            if (parsed.kind_explicit) participant.kind = parsed.kind;
            return index;
        }
        if (self.seq.participant_count >= max_participants) {
            self.seq.degraded = true;
            return null;
        }
        const index = self.seq.participant_count;
        self.seq.participants[index] = .{ .id = parsed.id, .label = parsed.label, .kind = parsed.kind };
        self.seq.participant_count += 1;
        return index;
    }

    fn addNote(self: *SeqParser, kind: NoteKind, a: []const u8, b: ?[]const u8, text: []const u8) void {
        _ = self.intern(a) orelse return;
        if (b) |other| _ = self.intern(other) orelse return;
        if (self.seq.note_count >= max_notes) {
            self.seq.degraded = true;
            return;
        }
        self.seq.notes[self.seq.note_count] = .{ .kind = kind, .a = a, .b = b, .text = text, .pos = self.pos };
        self.seq.note_count += 1;
        self.pos += 1;
    }

    fn addMessage(self: *SeqParser, m: ParsedMessage) void {
        const s = self.intern(m.src) orelse return;
        const d = self.intern(m.dst) orelse return;
        if (self.seq.participants[s].destroyed_at != null or self.seq.participants[d].destroyed_at != null) {
            self.supported = false;
            return;
        }
        if (self.pending_lifecycle) |pending| {
            switch (pending) {
                .create => |participant| if (d != participant) {
                    self.supported = false;
                    return;
                },
                .destroy => |participant| if (s != participant and d != participant) {
                    self.supported = false;
                    return;
                },
            }
        }
        if (self.seq.message_count >= max_messages) {
            self.seq.degraded = true;
            return;
        }
        self.seq.messages[self.seq.message_count] = .{
            .src = m.src,
            .dst = m.dst,
            .style = m.style,
            .src_endpoint = m.src_endpoint,
            .dst_endpoint = m.dst_endpoint,
            .central = m.central,
            .number = if (self.seq.autonumber != null) self.next_sequence_number else null,
            .text = m.text,
            .pos = self.pos,
        };
        self.seq.message_count += 1;
        if (self.seq.autonumber) |autonumber| self.next_sequence_number += autonumber.increment;
        if (self.pending_lifecycle) |pending| {
            switch (pending) {
                .create => |participant| self.seq.participants[participant].created_at = self.pos,
                .destroy => |participant| {
                    self.seq.participants[participant].destroyed_at = self.pos;
                    self.endAllActivations(participant, self.pos + 1);
                },
            }
            self.pending_lifecycle = null;
        }
        self.pos += 1;
        if (m.plus) self.startActivation(d, self.pos - 1);
        if (m.minus) self.endActivation(s, self.pos);
    }

    fn feedActorMetadata(self: *SeqParser, line: []const u8) bool {
        if (stripKeyword(line, "links")) |statement| {
            const parsed = splitActorStatement(statement) orelse {
                self.supported = false;
                return true;
            };
            const uri = findFirstUrl(parsed.payload) orelse {
                self.supported = false;
                return true;
            };
            const participant = self.intern(parsed.actor) orelse return true;
            if (self.seq.participants[participant].link == null) self.seq.participants[participant].link = uri;
            return true;
        }
        if (stripKeyword(line, "link")) |statement| {
            const parsed = splitActorStatement(statement) orelse {
                self.supported = false;
                return true;
            };
            const separator = mem.indexOfScalar(u8, parsed.payload, '@') orelse {
                self.supported = false;
                return true;
            };
            const uri = mem.trim(u8, parsed.payload[separator + 1 ..], " \t");
            if (uri.len == 0) {
                self.supported = false;
                return true;
            }
            const participant = self.intern(parsed.actor) orelse return true;
            if (self.seq.participants[participant].link == null) self.seq.participants[participant].link = uri;
            return true;
        }
        for ([_][]const u8{ "properties", "details" }) |keyword| {
            if (stripKeyword(line, keyword)) |statement| {
                const parsed = splitActorStatement(statement) orelse {
                    self.supported = false;
                    return true;
                };
                if (parsed.payload.len == 0)
                    self.supported = false
                else
                    self.addNote(.over, parsed.actor, null, parsed.payload);
                return true;
            }
        }
        return false;
    }

    fn feedMetadata(self: *SeqParser, line: []const u8) bool {
        if (stripColonDirective(line, "title")) |title| {
            if (title.len == 0) self.supported = false else self.seq.title = title;
            return true;
        }
        if (stripKeyword(line, "title")) |title| {
            if (title.len == 0) self.supported = false else self.seq.title = title;
            return true;
        }
        if (stripColonDirective(line, "accTitle") != null) return true;
        if (stripColonDirective(line, "accDescr") != null) return true;
        if (stripKeyword(line, "accDescr")) |rest| {
            if (rest.len == 0 or rest[0] != '{') {
                self.supported = false;
            } else if (mem.indexOfScalar(u8, rest[1..], '}') == null) {
                self.reading_accessibility_description = true;
            }
            return true;
        }
        return false;
    }

    fn feedLifecycle(self: *SeqParser, line: []const u8) bool {
        if (stripKeyword(line, "create")) |declaration| {
            const participant = parseParticipantLine(declaration) orelse {
                self.supported = false;
                return true;
            };
            if (self.findParticipant(participant.id) != null) {
                self.supported = false;
                return true;
            }
            const index = self.addParticipant(participant) orelse return true;
            self.pending_lifecycle = .{ .create = index };
            return true;
        }
        if (stripKeyword(line, "destroy")) |raw_id| {
            const id = parseActorId(raw_id) orelse {
                self.supported = false;
                return true;
            };
            const index = self.findParticipant(id) orelse {
                self.supported = false;
                return true;
            };
            if (self.seq.participants[index].destroyed_at != null) {
                self.supported = false;
                return true;
            }
            self.pending_lifecycle = .{ .destroy = index };
            return true;
        }
        return false;
    }

    fn findParticipant(self: *const SeqParser, id: []const u8) ?usize {
        for (self.seq.participants[0..self.seq.participant_count], 0..) |participant, index| {
            if (mem.eql(u8, participant.id, id)) return index;
        }
        return null;
    }

    fn startParticipantBox(self: *SeqParser, descriptor: []const u8) void {
        if (self.seq.participant_box_count >= max_participant_boxes) {
            self.seq.degraded = true;
            return;
        }
        const box_data = parseParticipantBox(descriptor) orelse {
            self.supported = false;
            return;
        };
        const index = self.seq.participant_box_count;
        self.seq.participant_boxes[index] = .{
            .label = box_data.label,
            .color = box_data.color,
            .first = self.seq.participant_count,
            .count = 0,
        };
        self.seq.participant_box_count += 1;
        self.open_participant_box = index;
    }

    fn closeParticipantBox(self: *SeqParser) void {
        const index = self.open_participant_box orelse return;
        const box = &self.seq.participant_boxes[index];
        box.count = self.seq.participant_count - box.first;
        if (box.count == 0) self.supported = false;
        self.open_participant_box = null;
    }

    fn startActivation(self: *SeqParser, idx: usize, at: usize) void {
        if (self.seq.activation_count + self.pending_activation_count >= max_activations) {
            self.seq.degraded = true;
            return;
        }
        var depth: usize = 0;
        for (self.pending_activations[0..self.pending_activation_count]) |pending| {
            if (pending.participant == idx) depth += 1;
        }
        self.pending_activations[self.pending_activation_count] = .{
            .participant = idx,
            .start = at,
            .depth = depth,
        };
        self.pending_activation_count += 1;
    }

    fn endActivation(self: *SeqParser, idx: usize, at: usize) void {
        const index = self.pendingActivationIndex(idx) orelse {
            self.supported = false;
            return;
        };
        self.closeActivation(index, at);
    }

    fn endAllActivations(self: *SeqParser, participant: usize, at: usize) void {
        while (self.pendingActivationIndex(participant)) |index| self.closeActivation(index, at);
    }

    fn pendingActivationIndex(self: *const SeqParser, participant: usize) ?usize {
        var i = self.pending_activation_count;
        while (i > 0) {
            i -= 1;
            if (self.pending_activations[i].participant == participant) return i;
        }
        return null;
    }

    fn closeActivation(self: *SeqParser, index: usize, at: usize) void {
        self.appendActivation(self.pending_activations[index], at);
        var shift = index;
        while (shift + 1 < self.pending_activation_count) : (shift += 1) {
            self.pending_activations[shift] = self.pending_activations[shift + 1];
        }
        self.pending_activation_count -= 1;
    }

    fn appendActivation(self: *SeqParser, pending: PendingActivation, end: usize) void {
        if (self.seq.activation_count >= max_activations) {
            self.seq.degraded = true;
            return;
        }
        self.seq.activations[self.seq.activation_count] = .{
            .actor = self.seq.participants[pending.participant].id,
            .start = pending.start,
            .end = end,
            .depth = pending.depth,
        };
        self.seq.activation_count += 1;
    }

    fn feedControl(self: *SeqParser, line: []const u8) bool {
        if (stripKeyword(line, "autonumber")) |options| {
            if (eqlIgnoreCase(options, "off")) {
                self.seq.autonumber = null;
                return true;
            }
            self.seq.autonumber = parseAutonumber(options) orelse {
                self.supported = false;
                return true;
            };
            self.next_sequence_number = self.seq.autonumber.?.start;
            return true;
        }
        if (stripKeyword(line, "activate")) |raw_id| {
            const id = parseActorId(raw_id) orelse {
                self.supported = false;
                return true;
            };
            if (self.intern(id)) |idx| self.startActivation(idx, self.pos);
            return true;
        }
        if (stripKeyword(line, "deactivate")) |raw_id| {
            const id = parseActorId(raw_id) orelse {
                self.supported = false;
                return true;
            };
            if (self.intern(id)) |idx| self.endActivation(idx, self.pos);
            return true;
        }
        const blocks = [_]struct { kw: []const u8, op: FragmentOp }{
            .{ .kw = "loop", .op = .loop },
            .{ .kw = "alt", .op = .alt },
            .{ .kw = "opt", .op = .opt },
            .{ .kw = "par", .op = .par },
            .{ .kw = "par_over", .op = .par_over },
            .{ .kw = "critical", .op = .critical },
            .{ .kw = "break", .op = .@"break" },
            .{ .kw = "rect", .op = .rect },
        };
        for (blocks) |b| {
            if (stripKeyword(line, b.kw)) |label| {
                self.push(b.op, label);
                return true;
            }
        }
        if (stripKeyword(line, "box")) |label| {
            self.startParticipantBox(label);
            return true;
        }
        if (stripKeyword(line, "and")) |label| {
            if (!self.topIs(.par) and !self.topIs(.par_over)) self.supported = false else self.div("and", label);
            return true;
        }
        if (stripKeyword(line, "else")) |label| {
            if (!self.topIs(.alt)) self.supported = false else self.div("else", label);
            return true;
        }
        if (stripKeyword(line, "option")) |label| {
            if (!self.topIs(.critical)) self.supported = false else self.div("option", label);
            return true;
        }
        if (stripKeyword(line, "end")) |tail| {
            if (tail.len > 0 or self.stack_len == 0) self.supported = false else self.close();
            return true;
        }
        return false;
    }

    fn topIs(self: *const SeqParser, op: FragmentOp) bool {
        if (self.stack_len == 0) return false;
        return self.seq.fragments[self.stack[self.stack_len - 1]].op == op;
    }

    fn push(self: *SeqParser, op: FragmentOp, label: []const u8) void {
        if (self.stack_len >= max_fragment_depth or self.seq.fragment_count >= max_fragments) {
            self.seq.degraded = true;
            return;
        }
        const idx = self.seq.fragment_count;
        self.seq.fragments[idx] = .{
            .op = op,
            .label = label,
            .start = self.pos,
            .end = self.pos,
            .depth = self.stack_len,
        };
        self.seq.fragment_count += 1;
        self.stack[self.stack_len] = idx;
        self.stack_len += 1;
    }

    fn close(self: *SeqParser) void {
        if (self.stack_len == 0) return;
        self.stack_len -= 1;
        self.seq.fragments[self.stack[self.stack_len]].end = self.pos;
    }

    fn div(self: *SeqParser, head: []const u8, label: []const u8) void {
        const frag = &self.seq.fragments[self.stack[self.stack_len - 1]];
        if (frag.div_count >= frag.divs.len) {
            self.seq.degraded = true;
            return;
        }
        frag.divs[frag.div_count] = .{ .pos = self.pos, .head = head, .text = label };
        frag.div_count += 1;
    }
};

const ActorStatement = struct {
    actor: []const u8,
    payload: []const u8,
};

fn splitActorStatement(statement: []const u8) ?ActorStatement {
    const colon = mem.indexOfScalar(u8, statement, ':') orelse return null;
    const actor = parseActorId(statement[0..colon]) orelse return null;
    const payload = mem.trim(u8, statement[colon + 1 ..], " \t");
    if (payload.len == 0) return null;
    return .{ .actor = actor, .payload = payload };
}

fn findFirstUrl(text: []const u8) ?[]const u8 {
    const start = mem.indexOf(u8, text, "https://") orelse mem.indexOf(u8, text, "http://") orelse return null;
    var end = start;
    while (end < text.len and text[end] != '"' and text[end] != '\'' and text[end] != ',' and text[end] != '}' and
        text[end] != ' ' and text[end] != '\t') : (end += 1)
    {}
    return text[start..end];
}

fn stripColonDirective(line: []const u8, name: []const u8) ?[]const u8 {
    if (line.len <= name.len or !eqlIgnoreCase(line[0..name.len], name) or line[name.len] != ':') return null;
    return mem.trim(u8, line[name.len + 1 ..], " \t");
}

fn stripSequenceComment(line: []const u8) []const u8 {
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        if (line[i] != '#') continue;
        const semicolon = mem.indexOfScalarPos(u8, line, i + 1, ';');
        if (semicolon) |end| {
            var entity = true;
            for (line[i + 1 .. end]) |char| {
                if (!ascii.isAlphanumeric(char)) {
                    entity = false;
                    break;
                }
            }
            if (entity) {
                i = end;
                continue;
            }
        }
        return line[0..i];
    }
    return line;
}

fn isEntitySemicolon(text: []const u8, semicolon: usize) bool {
    var start = semicolon;
    while (start > 0 and ascii.isAlphanumeric(text[start - 1])) start -= 1;
    return start > 0 and (text[start - 1] == '#' or text[start - 1] == '&');
}

fn boundary(s: []const u8, n: usize) bool {
    return s.len == n or s[n] == ' ' or s[n] == '\t';
}

fn stripKeyword(s: []const u8, kw: []const u8) ?[]const u8 {
    if (s.len < kw.len or !eqlIgnoreCase(s[0..kw.len], kw) or !boundary(s, kw.len)) return null;
    return mem.trim(u8, s[kw.len..], " \t");
}

fn parseAutonumber(raw: []const u8) ?Autonumber {
    const options = mem.trim(u8, raw, " \t");
    if (options.len == 0) return .{ .start = 100, .increment = 100 };
    var tokens = mem.tokenizeAny(u8, options, " \t");
    const start = parseHundredths(tokens.next() orelse return null) orelse return null;
    const increment = if (tokens.next()) |token| parseHundredths(token) orelse return null else 100;
    if (tokens.next() != null) return null;
    return .{ .start = start, .increment = increment };
}

fn parseHundredths(raw: []const u8) ?u32 {
    if (raw.len == 0) return null;
    const dot = mem.indexOfScalar(u8, raw, '.');
    const whole_text = if (dot) |index| raw[0..index] else raw;
    const fraction_text = if (dot) |index| raw[index + 1 ..] else "";
    if (whole_text.len == 0 and fraction_text.len == 0) return null;
    if (fraction_text.len > 2 or mem.indexOfScalar(u8, fraction_text, '.') != null) return null;

    var whole: u32 = 0;
    for (whole_text) |digit| {
        if (!ascii.isDigit(digit)) return null;
        const value: u32 = digit - '0';
        if (whole > (std.math.maxInt(u32) - value) / 10) return null;
        whole = whole * 10 + value;
    }
    var fraction: u32 = 0;
    for (fraction_text) |digit| {
        if (!ascii.isDigit(digit)) return null;
        fraction = fraction * 10 + digit - '0';
    }
    if (fraction_text.len == 1) fraction *= 10;
    if (whole > (std.math.maxInt(u32) - fraction) / 100) return null;
    return whole * 100 + fraction;
}

fn parseActorId(raw: []const u8) ?[]const u8 {
    const id = mem.trim(u8, raw, " \t");
    if (id.len == 0) return null;
    for (id) |char| {
        if (char == '<' or char == '>' or char == ':' or char == ',' or char == ';' or char == '@' or char == '\n' or char == '\r') return null;
    }
    return id;
}

const ParsedParticipant = struct {
    id: []const u8,
    label: []const u8,
    label_explicit: bool,
    kind: ParticipantKind,
    kind_explicit: bool,
};

const ParticipantMetadata = struct {
    alias: ?[]const u8 = null,
    kind: ?ParticipantKind = null,
};

fn findKeywordSeparator(text: []const u8, keyword: []const u8) ?usize {
    if (text.len < keyword.len + 2) return null;
    var i: usize = 1;
    while (i + keyword.len < text.len) : (i += 1) {
        if (text[i - 1] != ' ' and text[i - 1] != '\t') continue;
        if (!eqlIgnoreCase(text[i .. i + keyword.len], keyword)) continue;
        const after = text[i + keyword.len];
        if (after == ' ' or after == '\t') return i;
    }
    return null;
}

fn parseParticipantLine(line: []const u8) ?ParsedParticipant {
    const parsed_keyword: struct { rest: []const u8, kind: ParticipantKind } = if (stripKeyword(line, "participant")) |rest|
        .{ .rest = rest, .kind = ParticipantKind.participant }
    else if (stripKeyword(line, "actor")) |rest|
        .{ .rest = rest, .kind = ParticipantKind.actor }
    else
        return null;
    const metadata_start = mem.indexOf(u8, parsed_keyword.rest, "@{");
    const alias_start = if (metadata_start == null) findKeywordSeparator(parsed_keyword.rest, "as") else null;
    const id_end = metadata_start orelse alias_start orelse parsed_keyword.rest.len;
    const id = parseActorId(parsed_keyword.rest[0..id_end]) orelse return null;
    var after = mem.trim(u8, parsed_keyword.rest[id_end..], " \t");
    var label = id;
    var label_explicit = false;
    var kind = parsed_keyword.kind;
    var kind_explicit = kind == .actor;
    if (mem.startsWith(u8, after, "@{")) {
        const close = mem.indexOfScalar(u8, after, '}') orelse return null;
        const metadata = parseParticipantMetadata(after[2..close]) orelse return null;
        if (metadata.alias) |alias| {
            label = alias;
            label_explicit = true;
        }
        if (metadata.kind) |participant_kind| {
            kind = participant_kind;
            kind_explicit = true;
        }
        after = mem.trim(u8, after[close + 1 ..], " \t");
    }
    if (after.len > 0) {
        const external_alias = stripKeyword(after, "as") orelse return null;
        if (external_alias.len == 0) return null;
        label = external_alias;
        label_explicit = true;
    }
    return .{
        .id = id,
        .label = label,
        .label_explicit = label_explicit,
        .kind = kind,
        .kind_explicit = kind_explicit,
    };
}

fn parseParticipantMetadata(body: []const u8) ?ParticipantMetadata {
    var metadata: ParticipantMetadata = .{};
    var start: usize = 0;
    var quoted = false;
    var i: usize = 0;
    while (i <= body.len) : (i += 1) {
        const at_end = i == body.len;
        if (!at_end and body[i] == '"') quoted = !quoted;
        if (!at_end and (body[i] != ',' or quoted)) continue;
        if (quoted) return null;
        const field = mem.trim(u8, body[start..i], " \t");
        const colon = mem.indexOfScalar(u8, field, ':') orelse return null;
        const key = metadataValue(field[0..colon]) orelse return null;
        const value = metadataValue(field[colon + 1 ..]) orelse return null;
        if (mem.eql(u8, key, "alias")) {
            if (value.len == 0) return null;
            metadata.alias = value;
        } else if (mem.eql(u8, key, "type")) {
            metadata.kind = parseParticipantKind(value) orelse return null;
        } else {
            return null;
        }
        start = i + 1;
    }
    return metadata;
}

const ParticipantBoxData = struct {
    label: []const u8,
    color: ?[]const u8,
};

fn parseParticipantBox(raw: []const u8) ?ParticipantBoxData {
    const descriptor = mem.trim(u8, raw, " \t");
    if (descriptor.len == 0) return null;
    for ([_][]const u8{ "rgb(", "rgba(", "hsl(", "hsla(" }) |prefix| {
        if (!mem.startsWith(u8, descriptor, prefix)) continue;
        const close = mem.indexOfScalar(u8, descriptor, ')') orelse return null;
        return .{
            .label = mem.trim(u8, descriptor[close + 1 ..], " \t"),
            .color = descriptor[0 .. close + 1],
        };
    }
    var word_end: usize = 0;
    while (word_end < descriptor.len and descriptor[word_end] != ' ' and descriptor[word_end] != '\t') : (word_end += 1) {}
    const color = descriptor[0..word_end];
    for ([_][]const u8{
        "transparent", "black", "silver", "gray",   "white", "maroon", "red",  "purple", "fuchsia",
        "green",       "lime",  "olive",  "yellow", "navy",  "blue",   "teal", "aqua",   "orange",
    }) |name| {
        if (eqlIgnoreCase(color, name)) return .{
            .label = mem.trim(u8, descriptor[word_end..], " \t"),
            .color = color,
        };
    }
    return .{ .label = descriptor, .color = null };
}

fn parseParticipantKind(value: []const u8) ?ParticipantKind {
    inline for (std.meta.fields(ParticipantKind)) |field| {
        if (eqlIgnoreCase(value, field.name)) return @enumFromInt(field.value);
    }
    return null;
}

const ParsedNote = struct {
    kind: NoteKind,
    a: []const u8,
    b: ?[]const u8,
    text: []const u8,
};

fn parseNoteLine(line: []const u8) ?ParsedNote {
    const rest = stripKeyword(line, "Note") orelse return null;
    if (stripKeyword(rest, "over")) |after| {
        const ci = mem.indexOfScalar(u8, after, ':') orelse return null;
        const actors = mem.trim(u8, after[0..ci], " \t");
        const text = mem.trim(u8, after[ci + 1 ..], " \t");
        if (mem.indexOfScalar(u8, actors, ',')) |comma| {
            const a = parseActorId(actors[0..comma]) orelse return null;
            const b = parseActorId(actors[comma + 1 ..]) orelse return null;
            return .{ .kind = .over, .a = a, .b = b, .text = text };
        }
        return .{ .kind = .over, .a = parseActorId(actors) orelse return null, .b = null, .text = text };
    }
    for ([_]struct { kw: []const u8, kind: NoteKind }{ .{ .kw = "left", .kind = .left }, .{ .kw = "right", .kind = .right } }) |side| {
        const after_side = stripKeyword(rest, side.kw) orelse continue;
        const after_of = stripKeyword(after_side, "of") orelse return null;
        const ci = mem.indexOfScalar(u8, after_of, ':') orelse return null;
        const actor = parseActorId(after_of[0..ci]) orelse return null;
        return .{ .kind = side.kind, .a = actor, .b = null, .text = mem.trim(u8, after_of[ci + 1 ..], " \t") };
    }
    return null;
}

const ParsedMessage = struct {
    src: []const u8,
    dst: []const u8,
    style: MsgStyle,
    src_endpoint: MsgEndpoint,
    dst_endpoint: MsgEndpoint,
    central: CentralConnection,
    text: []const u8,
    plus: bool,
    minus: bool,
};

const MsgToken = struct {
    style: MsgStyle,
    len: usize,
    src_endpoint: MsgEndpoint = .none,
    dst_endpoint: MsgEndpoint = .none,
};

fn matchMsgToken(rest: []const u8) ?MsgToken {
    if (mem.startsWith(u8, rest, "<<-->>")) return .{ .style = .dotted, .len = 6, .src_endpoint = .arrow, .dst_endpoint = .arrow };
    if (mem.startsWith(u8, rest, "<<->>")) return .{ .style = .solid, .len = 5, .src_endpoint = .arrow, .dst_endpoint = .arrow };

    if (mem.startsWith(u8, rest, "--|\\")) return .{ .style = .dotted, .len = 4, .dst_endpoint = .half_top };
    if (mem.startsWith(u8, rest, "--|/")) return .{ .style = .dotted, .len = 4, .dst_endpoint = .half_bottom };
    if (mem.startsWith(u8, rest, "--\\\\")) return .{ .style = .dotted, .len = 4, .dst_endpoint = .stick_top };
    if (mem.startsWith(u8, rest, "--//")) return .{ .style = .dotted, .len = 4, .dst_endpoint = .stick_bottom };
    if (mem.startsWith(u8, rest, "/|--")) return .{ .style = .dotted, .len = 4, .src_endpoint = .half_top };
    if (mem.startsWith(u8, rest, "\\|--")) return .{ .style = .dotted, .len = 4, .src_endpoint = .half_bottom };
    if (mem.startsWith(u8, rest, "//--")) return .{ .style = .dotted, .len = 4, .src_endpoint = .stick_top };
    if (mem.startsWith(u8, rest, "\\\\--")) return .{ .style = .dotted, .len = 4, .src_endpoint = .stick_bottom };

    if (mem.startsWith(u8, rest, "-|\\")) return .{ .style = .solid, .len = 3, .dst_endpoint = .half_top };
    if (mem.startsWith(u8, rest, "-|/")) return .{ .style = .solid, .len = 3, .dst_endpoint = .half_bottom };
    if (mem.startsWith(u8, rest, "-\\\\")) return .{ .style = .solid, .len = 3, .dst_endpoint = .stick_top };
    if (mem.startsWith(u8, rest, "-//")) return .{ .style = .solid, .len = 3, .dst_endpoint = .stick_bottom };
    if (mem.startsWith(u8, rest, "/|-")) return .{ .style = .solid, .len = 3, .src_endpoint = .half_top };
    if (mem.startsWith(u8, rest, "\\|-")) return .{ .style = .solid, .len = 3, .src_endpoint = .half_bottom };
    if (mem.startsWith(u8, rest, "//-")) return .{ .style = .solid, .len = 3, .src_endpoint = .stick_top };
    if (mem.startsWith(u8, rest, "\\\\-")) return .{ .style = .solid, .len = 3, .src_endpoint = .stick_bottom };

    if (mem.startsWith(u8, rest, "-->>")) return .{ .style = .dotted, .len = 4, .dst_endpoint = .arrow };
    if (mem.startsWith(u8, rest, "->>")) return .{ .style = .solid, .len = 3, .dst_endpoint = .arrow };
    if (mem.startsWith(u8, rest, "-->")) return .{ .style = .dotted, .len = 3 };
    if (mem.startsWith(u8, rest, "->")) return .{ .style = .solid, .len = 2 };
    if (mem.startsWith(u8, rest, "--x")) return .{ .style = .dotted, .len = 3, .dst_endpoint = .cross };
    if (mem.startsWith(u8, rest, "-x")) return .{ .style = .solid, .len = 2, .dst_endpoint = .cross };
    if (mem.startsWith(u8, rest, "--)")) return .{ .style = .dotted, .len = 3, .dst_endpoint = .open };
    if (mem.startsWith(u8, rest, "-)")) return .{ .style = .solid, .len = 2, .dst_endpoint = .open };
    return null;
}

fn parseMessageLine(line: []const u8) ?ParsedMessage {
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        const arrow = matchMsgToken(line[i..]) orelse continue;
        var raw_src = mem.trim(u8, line[0..i], " \t");
        var source_central = false;
        if (mem.endsWith(u8, raw_src, "()")) {
            source_central = true;
            raw_src = mem.trim(u8, raw_src[0 .. raw_src.len - 2], " \t");
        }
        const src = parseActorId(raw_src) orelse continue;
        var j = i + arrow.len;
        while (j < line.len and (line[j] == ' ' or line[j] == '\t')) j += 1;
        var destination_central = false;
        if (mem.startsWith(u8, line[j..], "()")) {
            destination_central = true;
            j += 2;
            while (j < line.len and (line[j] == ' ' or line[j] == '\t')) j += 1;
        }
        var plus = false;
        var minus = false;
        if (j < line.len and (line[j] == '+' or line[j] == '-')) {
            if (line[j] == '+') plus = true else minus = true;
            j += 1;
            while (j < line.len and (line[j] == ' ' or line[j] == '\t')) j += 1;
        }
        const colon = mem.indexOfScalarPos(u8, line, j, ':');
        const actor_end = colon orelse line.len;
        const dst = parseActorId(line[j..actor_end]) orelse continue;
        const text = if (colon) |index| normalizeMessageText(line[index + 1 ..]) else "";
        const central: CentralConnection = if (source_central and destination_central)
            .both
        else if (source_central)
            .source
        else if (destination_central)
            .destination
        else
            .none;
        return .{
            .src = src,
            .dst = dst,
            .style = arrow.style,
            .src_endpoint = arrow.src_endpoint,
            .dst_endpoint = arrow.dst_endpoint,
            .central = central,
            .text = text,
            .plus = plus,
            .minus = minus,
        };
    }
    return null;
}

fn normalizeMessageText(raw: []const u8) []const u8 {
    const text = mem.trim(u8, raw, " \t");
    for ([_][]const u8{ "wrap:", "nowrap:" }) |prefix| {
        if (text.len >= prefix.len and eqlIgnoreCase(text[0..prefix.len], prefix)) return mem.trim(u8, text[prefix.len..], " \t");
    }
    return text;
}

fn feedLines(parser: anytype, text: []const u8) void {
    var rest = text;
    while (rest.len > 0) {
        const nl = mem.indexOfScalar(u8, rest, '\n') orelse rest.len;
        parser.feed(rest[0..nl]);
        rest = if (nl < rest.len) rest[nl + 1 ..] else "";
    }
}

fn isComment(line: []const u8) bool {
    return mem.startsWith(u8, line, "%%") and !mem.startsWith(u8, line, "%%{");
}

fn isConfigDirective(line: []const u8) bool {
    return mem.startsWith(u8, line, "%%{") and mem.endsWith(u8, line, "}%%");
}

fn metadataValue(raw: []const u8) ?[]const u8 {
    const value = mem.trim(u8, raw, " \t\r");
    if (value.len == 0) return null;
    if (value[0] != '"') return value;
    if (value.len < 2 or value[value.len - 1] != '"') return null;
    return value[1 .. value.len - 1];
}

fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (ascii.toLower(x) != ascii.toLower(y)) return false;
    }
    return true;
}

const std = @import("std");
const Document = @import("../Document.zig");
const mem = std.mem;
const ascii = std.ascii;

test "spaces around arrows" {
    const seq = parseSequenceBlockText(
        "sequenceDiagram\n" ++
            "A ->> B: one\n" ++
            "A->> B: two\n" ++
            "A ->>B: three\n" ++
            "A --x B: four\n" ++
            "A->>+ B: five\n",
    ).?;
    try testing.expectEqual(@as(usize, 5), seq.message_count);
    try testing.expectEqualStrings("one", seq.messages[0].text);
    try testing.expectEqualStrings("two", seq.messages[1].text);
    try testing.expectEqualStrings("three", seq.messages[2].text);
    try testing.expect(seq.messages[3].dst_endpoint == .cross);
    try testing.expectEqual(@as(usize, 1), seq.activation_count);
    try testing.expectEqualStrings("B", seq.activations[0].actor);
}

test "sequence participants" {
    const seq = parseSequenceBlockText(
        "sequenceDiagram\n" ++
            "participant A as Alice\n" ++
            "B->>A: hi\n" ++
            "participant B as Bob\n" ++
            "actor C as Carol\n" ++
            "participant A\n",
    ).?;
    try testing.expectEqual(@as(usize, 3), seq.participant_count);
    try testing.expectEqualStrings("Alice", seq.participants[0].label);
    try testing.expectEqualStrings("Bob", seq.participants[1].label);
    try testing.expectEqualStrings("Carol", seq.participants[2].label);
    try testing.expect(!seq.degraded);
}

test "sequence participant stereotypes and aliases" {
    const seq = parseSequenceBlockText(
        "sequenceDiagram\n" ++
            "participant API@{ \"type\": \"boundary\", \"alias\": \"Internal API\" } as Public API\n" ++
            "actor DB@{ \"type\": \"database\" } as Database\n" ++
            "participant Q@{ \"type\": \"queue\" }\n",
    ).?;
    try testing.expectEqual(@as(usize, 3), seq.participant_count);
    try testing.expect(seq.participants[0].kind == .boundary);
    try testing.expectEqualStrings("Public API", seq.participants[0].label);
    try testing.expect(seq.participants[1].kind == .database);
    try testing.expectEqualStrings("Database", seq.participants[1].label);
    try testing.expect(seq.participants[2].kind == .queue);
}

test "sequence participant boxes" {
    const seq = parseSequenceBlockText(
        "sequenceDiagram\n" ++
            "box Purple Services\n" ++
            "participant A\n" ++
            "actor B as Bob\n" ++
            "end\n" ++
            "box rgb(10, 20, 30)\n" ++
            "participant C\n" ++
            "end\n" ++
            "A->>C: hello\n",
    ).?;
    try testing.expectEqual(@as(usize, 2), seq.participant_box_count);
    try testing.expectEqualStrings("Services", seq.participant_boxes[0].label);
    try testing.expectEqualStrings("Purple", seq.participant_boxes[0].color.?);
    try testing.expectEqual(@as(usize, 0), seq.participant_boxes[0].first);
    try testing.expectEqual(@as(usize, 2), seq.participant_boxes[0].count);
    try testing.expectEqualStrings("", seq.participant_boxes[1].label);
    try testing.expectEqualStrings("rgb(10, 20, 30)", seq.participant_boxes[1].color.?);
    try testing.expectEqual(@as(usize, 2), seq.participant_boxes[1].first);
    try testing.expectEqual(@as(usize, 1), seq.participant_boxes[1].count);
}

test "sequence actor creation and destruction" {
    const seq = parseSequenceBlockText(
        "sequenceDiagram\n" ++
            "participant A\n" ++
            "create participant B as Bob\n" ++
            "A->>B: hello\n" ++
            "activate B\n" ++
            "destroy B\n" ++
            "B--xA: bye\n",
    ).?;
    try testing.expectEqual(@as(usize, 2), seq.participant_count);
    try testing.expect(seq.participants[0].created_at == null);
    try testing.expectEqual(@as(?usize, 0), seq.participants[1].created_at);
    try testing.expectEqual(@as(?usize, 1), seq.participants[1].destroyed_at);
    try testing.expectEqual(@as(usize, 1), seq.activation_count);
    try testing.expectEqual(@as(usize, 2), seq.activations[0].end);
}

test "unsupported sequence participant state is rejected" {
    for ([_][]const u8{
        "sequenceDiagram\ncreate participant B\nA->>C: wrong\n",
        "sequenceDiagram\ndestroy Missing\nA->>B: wrong\n",
        "sequenceDiagram\nbox Empty\nend\n",
        "sequenceDiagram\nbox Group\nparticipant A\nA->>B: inside\nend\n",
        "sequenceDiagram\nparticipant A\nparticipant B\ndestroy B\nA->>B: bye\nB->>A: after\n",
        "sequenceDiagram\nparticipant A@{ \"type\": \"unknown\" }\n",
    }) |text| {
        try testing.expect(parseSequenceBlockText(text) == null);
    }
}

test "sequence actor metadata and configuration" {
    const seq = parseSequenceBlockText(
        "---\n" ++
            "config:\n" ++
            "  theme: dark\n" ++
            "---\n" ++
            "%%{init: {'themeVariables': {'primaryColor': '#fff'}}}%%\n" ++
            "sequenceDiagram\n" ++
            "participant Alice\n" ++
            "link Alice: Dashboard @ https://example.com/dashboard\n" ++
            "properties Alice: { role: admin }\n" ++
            "details Alice: Primary user\n" ++
            "links Bob: {\"Wiki\": \"https://example.com/wiki\"}\n" ++
            "Alice->>Bob: hello\n",
    ).?;
    try testing.expectEqualStrings("https://example.com/dashboard", seq.participants[0].link.?);
    try testing.expectEqualStrings("https://example.com/wiki", seq.participants[1].link.?);
    try testing.expectEqual(@as(usize, 2), seq.note_count);
}

test "sequence title and accessibility metadata" {
    const seq = parseSequenceBlockText(
        "sequenceDiagram\n" ++
            "title: Conversation\n" ++
            "accTitle: Accessible conversation\n" ++
            "accDescr {\n" ++
            "A conversation between services\n" ++
            "}\n" ++
            "A->>B: hello\n",
    ).?;
    try testing.expectEqualStrings("Conversation", seq.title.?);
}

test "sequence grammar compatibility" {
    const seq = parseSequenceBlockText(
        "SEQUENCEDIAGRAM; " ++
            "PARTICIPANT Alice-in-Wonderland; " ++
            "PARTICIPANT Service = API; " ++
            "PARTICIPANT A-x-id; " ++
            "AUTONUMBER 5; " ++
            "Alice-in-Wonderland->>Service = API: first; " ++
            "AUTONUMBER OFF; " ++
            "Service = API-->>Alice-in-Wonderland: second; " ++
            "A-x-id->>Alice-in-Wonderland: third\n",
    ).?;
    try testing.expectEqualStrings("Alice-in-Wonderland", seq.participants[0].id);
    try testing.expectEqualStrings("Service = API", seq.participants[1].id);
    try testing.expectEqualStrings("A-x-id", seq.participants[2].id);
    try testing.expectEqual(@as(?u64, 500), seq.messages[0].number);
    try testing.expect(seq.messages[1].number == null);
}

test "late boxes and lifecycle inside fragments" {
    const seq = parseSequenceBlockText(
        "sequenceDiagram\n" ++
            "A->>B: before\n" ++
            "box Later\n" ++
            "participant C\n" ++
            "end\n" ++
            "par_over work\n" ++
            "create actor D\n" ++
            "A->>D: create\n" ++
            "and finish\n" ++
            "destroy D\n" ++
            "D--xA: destroy\n" ++
            "end\n",
    ).?;
    try testing.expectEqual(@as(usize, 1), seq.participant_box_count);
    try testing.expect(seq.fragments[0].op == .par_over);
    try testing.expectEqual(@as(?usize, 1), seq.participants[3].created_at);
    try testing.expectEqual(@as(?usize, 2), seq.participants[3].destroyed_at);
}

test "sequence arrows" {
    const seq = parseSequenceBlockText(
        "sequenceDiagram\n" ++
            "A->B: plain\n" ++
            "A-->B: dotted\n" ++
            "A->>B: arrow\n" ++
            "A-->>B: dotted arrow\n" ++
            "A-xB: lost\n" ++
            "A--xB: dotted lost\n" ++
            "A-)B: open\n" ++
            "A--)B: dotted open\n" ++
            "A->>B\n",
    ).?;
    const messages = seq.messages[0..seq.message_count];
    try testing.expectEqual(@as(usize, 9), messages.len);
    try testing.expect(messages[0].style == .solid and messages[0].dst_endpoint == .none);
    try testing.expect(messages[1].style == .dotted and messages[1].dst_endpoint == .none);
    try testing.expect(messages[2].style == .solid and messages[2].dst_endpoint == .arrow);
    try testing.expect(messages[3].style == .dotted and messages[3].dst_endpoint == .arrow);
    try testing.expect(messages[4].style == .solid and messages[4].dst_endpoint == .cross);
    try testing.expect(messages[5].style == .dotted and messages[5].dst_endpoint == .cross);
    try testing.expectEqualStrings("open", messages[6].text);
    try testing.expect(messages[6].style == .solid and messages[6].dst_endpoint == .open);
    try testing.expect(messages[7].style == .dotted and messages[7].dst_endpoint == .open);
    try testing.expectEqualStrings("", messages[8].text);
    try testing.expectEqual(@as(usize, 0), messages[0].pos);
    try testing.expectEqual(@as(usize, 8), messages[8].pos);
}

test "sequence bidirectional arrows" {
    const seq = parseSequenceBlockText(
        "sequenceDiagram\n" ++
            "A<<->>B: solid\n" ++
            "B<<-->>A: dotted\n",
    ).?;
    try testing.expectEqual(@as(usize, 2), seq.message_count);
    try testing.expect(seq.messages[0].src_endpoint == .arrow and seq.messages[0].dst_endpoint == .arrow);
    try testing.expect(seq.messages[0].style == .solid);
    try testing.expect(seq.messages[1].src_endpoint == .arrow and seq.messages[1].dst_endpoint == .arrow);
    try testing.expect(seq.messages[1].style == .dotted);
}

test "sequence half arrows" {
    const seq = parseSequenceBlockText(
        "sequenceDiagram\n" ++
            "A-|\\B\n" ++
            "A-|/B\n" ++
            "A-\\\\B\n" ++
            "A-//B\n" ++
            "A--|\\B\n" ++
            "A--|/B\n" ++
            "A--\\\\B\n" ++
            "A--//B\n" ++
            "B/|-A\n" ++
            "B\\|-A\n" ++
            "B//-A\n" ++
            "B\\\\-A\n" ++
            "B/|--A\n" ++
            "B\\|--A\n" ++
            "B//--A\n" ++
            "B\\\\--A\n",
    ).?;
    try testing.expectEqual(@as(usize, 16), seq.message_count);
    const endpoints = [_]MsgEndpoint{ .half_top, .half_bottom, .stick_top, .stick_bottom };
    for (0..8) |index| {
        const style: MsgStyle = if (index < 4) .solid else .dotted;
        try testing.expect(seq.messages[index].dst_endpoint == endpoints[index % endpoints.len]);
        try testing.expect(seq.messages[index].style == style);
    }
    for (8..16) |index| {
        const style: MsgStyle = if (index < 12) .solid else .dotted;
        try testing.expect(seq.messages[index].src_endpoint == endpoints[index % endpoints.len]);
        try testing.expect(seq.messages[index].style == style);
    }
}

test "sequence central connections" {
    const seq = parseSequenceBlockText(
        "sequenceDiagram\n" ++
            "A->>()B: destination\n" ++
            "A()->>B: source\n" ++
            "A()->>()B: both\n" ++
            "A()<<-->>()B: bidirectional\n",
    ).?;
    try testing.expect(seq.messages[0].central == .destination);
    try testing.expect(seq.messages[1].central == .source);
    try testing.expect(seq.messages[2].central == .both);
    try testing.expect(seq.messages[3].central == .both);
    try testing.expect(seq.messages[3].src_endpoint == .arrow and seq.messages[3].dst_endpoint == .arrow);
    try testing.expect(parseSequenceBlockText("sequenceDiagram\nA()->>()A: self\n") != null);
}

test "sequence comments and wrap directives" {
    const seq = parseSequenceBlockText(
        "SEQUENCEDIAGRAM\n" ++
            "# a comment\n" ++
            "A->>B:wrap:hello # trailing comment\n",
    ).?;
    try testing.expectEqualStrings("hello", seq.messages[0].text);
}

test "sequence message text splits on first colon" {
    const seq = parseSequenceBlockText("sequenceDiagram\nA->>B: see http://x\n").?;
    try testing.expectEqualStrings("see http://x", seq.messages[0].text);
}

test "sequence notes" {
    const seq = parseSequenceBlockText(
        "sequenceDiagram\n" ++
            "Note over A,B: span\n" ++
            "Note over A: single\n" ++
            "Note left of A: to the left\n" ++
            "Note right of B: to the right\n",
    ).?;
    try testing.expectEqual(@as(usize, 4), seq.note_count);
    try testing.expect(seq.notes[0].kind == .over);
    try testing.expectEqualStrings("B", seq.notes[0].b.?);
    try testing.expect(seq.notes[1].b == null);
    try testing.expect(seq.notes[2].kind == .left);
    try testing.expect(seq.notes[3].kind == .right);
    try testing.expectEqualStrings("to the right", seq.notes[3].text);
    try testing.expectEqual(@as(usize, 2), seq.participant_count);
}

test "sequence fragments" {
    const seq = parseSequenceBlockText(
        "sequenceDiagram\n" ++
            "loop Every minute\n" ++
            "A->>B: ping\n" ++
            "alt ok\n" ++
            "B->>A: pong\n" ++
            "else bad\n" ++
            "B->>A: silence\n" ++
            "end\n" ++
            "opt maybe\n" ++
            "A->>B: again\n" ++
            "end\n" ++
            "end\n",
    ).?;
    try testing.expectEqual(@as(usize, 3), seq.fragment_count);
    try testing.expect(seq.fragments[0].op == .loop);
    try testing.expectEqualStrings("Every minute", seq.fragments[0].label);
    try testing.expectEqual(@as(usize, 0), seq.fragments[0].start);
    try testing.expectEqual(@as(usize, 4), seq.fragments[0].end);
    try testing.expectEqual(@as(usize, 0), seq.fragments[0].depth);
    try testing.expect(seq.fragments[1].op == .alt);
    try testing.expectEqual(@as(usize, 1), seq.fragments[1].start);
    try testing.expectEqual(@as(usize, 1), seq.fragments[1].div_count);
    try testing.expectEqual(@as(usize, 2), seq.fragments[1].divs[0].pos);
    try testing.expectEqualStrings("else", seq.fragments[1].divs[0].head);
    try testing.expectEqualStrings("bad", seq.fragments[1].divs[0].text);
    try testing.expectEqual(@as(usize, 3), seq.fragments[1].end);
    try testing.expectEqual(@as(usize, 1), seq.fragments[1].depth);
    try testing.expect(seq.fragments[2].op == .opt);
    try testing.expectEqual(@as(usize, 3), seq.fragments[2].start);
    try testing.expectEqual(@as(usize, 4), seq.fragments[2].end);
}

test "critical break and rect sequence fragments" {
    const seq = parseSequenceBlockText(
        "sequenceDiagram\n" ++
            "critical Connect\n" ++
            "A->>B: try\n" ++
            "option Timeout\n" ++
            "A->>B: retry\n" ++
            "end\n" ++
            "break Failed\n" ++
            "A->>B: stop\n" ++
            "end\n" ++
            "rect rgb(10, 20, 30)\n" ++
            "B->>A: done\n" ++
            "end\n",
    ).?;
    try testing.expectEqual(@as(usize, 3), seq.fragment_count);
    try testing.expect(seq.fragments[0].op == .critical);
    try testing.expectEqual(@as(usize, 1), seq.fragments[0].div_count);
    try testing.expectEqualStrings("option", seq.fragments[0].divs[0].head);
    try testing.expect(seq.fragments[1].op == .@"break");
    try testing.expect(seq.fragments[2].op == .rect);
}

test "unsupported sequence statements are rejected" {
    for ([_][]const u8{
        "sequenceDiagram\nA->>B: before\nnot sequence syntax\n",
        "sequenceDiagram\nloop forever\nA->>B: again\n",
    }) |text| {
        try testing.expect(parseSequenceBlockText(text) == null);
    }
}

test "par blocks are real fragments" {
    const seq = parseSequenceBlockText(
        "sequenceDiagram\n" ++
            "par one\n" ++
            "A->>B: inside\n" ++
            "end\n",
    ).?;
    try testing.expectEqual(@as(usize, 1), seq.fragment_count);
    try testing.expect(seq.fragments[0].op == .par);
    try testing.expectEqualStrings("one", seq.fragments[0].label);
    try testing.expectEqual(@as(usize, 0), seq.fragments[0].start);
    try testing.expectEqual(@as(usize, 1), seq.fragments[0].end);
}

test "sequence activations" {
    const seq = parseSequenceBlockText(
        "sequenceDiagram\n" ++
            "activate A\n" ++
            "A->>+B: hello\n" ++
            "B-->>-A: hi\n" ++
            "deactivate A\n" ++
            "A->>B: later\n",
    ).?;
    try testing.expectEqual(@as(usize, 2), seq.activation_count);
    try testing.expectEqualStrings("B", seq.activations[0].actor);
    try testing.expectEqual(@as(usize, 0), seq.activations[0].start);
    try testing.expectEqual(@as(usize, 2), seq.activations[0].end);
    try testing.expectEqualStrings("A", seq.activations[1].actor);
    try testing.expectEqual(@as(usize, 0), seq.activations[1].start);
    try testing.expectEqual(@as(usize, 2), seq.activations[1].end);
    try testing.expect(!seq.degraded);
}

test "stacked sequence activations" {
    const seq = parseSequenceBlockText(
        "sequenceDiagram\n" ++
            "activate A\n" ++
            "activate A\n" ++
            "A->>B: nested\n" ++
            "deactivate A\n" ++
            "A->>B: outer\n" ++
            "deactivate A\n",
    ).?;
    try testing.expectEqual(@as(usize, 2), seq.activation_count);
    try testing.expectEqual(@as(usize, 1), seq.activations[0].depth);
    try testing.expectEqual(@as(usize, 0), seq.activations[0].start);
    try testing.expectEqual(@as(usize, 1), seq.activations[0].end);
    try testing.expectEqual(@as(usize, 0), seq.activations[1].depth);
    try testing.expectEqual(@as(usize, 2), seq.activations[1].end);
}

test "sequence autonumber configuration" {
    const seq = parseSequenceBlockText("sequenceDiagram\nautonumber\nA->>B: x\n").?;
    try testing.expectEqual(@as(u32, 100), seq.autonumber.?.start);
    try testing.expectEqual(@as(u32, 100), seq.autonumber.?.increment);

    const configured = parseSequenceBlockText("sequenceDiagram\nautonumber 2.5 0.25\nA->>B: x\n").?;
    try testing.expectEqual(@as(u32, 250), configured.autonumber.?.start);
    try testing.expectEqual(@as(u32, 25), configured.autonumber.?.increment);

    const plain = parseSequenceBlockText("sequenceDiagram\nA->>B: x\n").?;
    try testing.expect(plain.autonumber == null);
    for ([_][]const u8{
        "sequenceDiagram\nautonumber 1.001 1\nA->>B: x\n",
        "sequenceDiagram\nautonumber x 1\nA->>B: x\n",
    }) |text| {
        try testing.expect(parseSequenceBlockText(text) == null);
    }
}

test "sequence over-cap degrades" {
    const many = parseSequenceBlockText("sequenceDiagram\n" ++ ("A->>B: x\n" ** 200)).?;
    try testing.expect(many.degraded);
    const activations = parseSequenceBlockText("sequenceDiagram\n" ++ ("activate A\n" ** 65)).?;
    try testing.expect(activations.degraded);
    var deep: [512]u8 = undefined;
    @memcpy(deep[0..16], "sequenceDiagram\n");
    var pos: usize = 16;
    for (0..12) |_| {
        @memcpy(deep[pos..][0..7], "loop x\n");
        pos += 7;
    }
    const nested = parseSequenceBlockText(deep[0..pos]).?;
    try testing.expect(nested.degraded);
}

test "sequence rejects non-sequences" {
    try testing.expect(parseSequenceBlockText("graph TD\nA-->B\n") == null);
    try testing.expect(parseSequenceBlockText("just text\n") == null);
    try testing.expect(parseSequenceBlockText("") == null);
    var doc = Document.init("```mermaid\nsequenceDiagram\nA->>B: x\n```\n");
    const seq = parseSequenceBlock(doc.next().?.code_block).?;
    try testing.expectEqual(@as(usize, 1), seq.message_count);
    var zig = Document.init("```zig\nsequenceDiagram\n```\n");
    try testing.expect(parseSequenceBlock(zig.next().?.code_block) == null);
}

test "six message conversation" {
    const seq = parseSequenceBlockText(
        "sequenceDiagram\n" ++
            "    Alice ->> Bob: Hello Bob, how are you?\n" ++
            "    Bob-->>John: How about you John?\n" ++
            "    Bob--x Alice: I am good thanks!\n" ++
            "    Bob-x John: I am good thanks!\n" ++
            "    Bob-->Alice: Checking with John...\n" ++
            "    Alice->John: Yes... John, how are you?\n",
    ).?;
    try testing.expectEqual(@as(usize, 3), seq.participant_count);
    try testing.expectEqualStrings("Alice", seq.participants[0].id);
    try testing.expectEqualStrings("Bob", seq.participants[1].id);
    try testing.expectEqualStrings("John", seq.participants[2].id);
    try testing.expectEqual(@as(usize, 6), seq.message_count);
    try testing.expect(seq.messages[0].dst_endpoint == .arrow);
    try testing.expect(seq.messages[2].dst_endpoint == .cross);
    try testing.expect(seq.messages[3].dst_endpoint == .cross);
    try testing.expectEqualStrings("Yes... John, how are you?", seq.messages[5].text);
}

test "sequence slices point into the input" {
    const text = "sequenceDiagram\nA->>B: hello\n";
    const seq = parseSequenceBlockText(text).?;
    try testing.expect(within(text, seq.messages[0].text));
    try testing.expect(within(text, seq.messages[0].src));
}

fn within(text: []const u8, slice: []const u8) bool {
    const start = @intFromPtr(text.ptr);
    const ptr = @intFromPtr(slice.ptr);
    return ptr >= start and ptr + slice.len <= start + text.len;
}

const testing = std.testing;
