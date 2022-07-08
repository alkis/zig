const Object = @This();

const std = @import("std");
const build_options = @import("build_options");
const assert = std.debug.assert;
const dwarf = std.dwarf;
const fs = std.fs;
const io = std.io;
const log = std.log.scoped(.link);
const macho = std.macho;
const math = std.math;
const mem = std.mem;
const sort = std.sort;
const trace = @import("../../tracy.zig").trace;

const Allocator = mem.Allocator;
const Atom = @import("Atom.zig");
const MachO = @import("../MachO.zig");
const MatchingSection = MachO.MatchingSection;

file: fs.File,
name: []const u8,

/// Data contents of the file. Includes sections, and data of load commands.
/// Excludes the backing memory for the header and load commands.
/// Initialized in `parse`.
contents: []const u8 = undefined,

file_offset: ?u32 = null,

header: macho.mach_header_64 = undefined,

load_commands: std.ArrayListUnmanaged(macho.LoadCommand) = .{},

segment_cmd_index: ?u16 = null,
text_section_index: ?u16 = null,
symtab_cmd_index: ?u16 = null,
dysymtab_cmd_index: ?u16 = null,
build_version_cmd_index: ?u16 = null,
data_in_code_cmd_index: ?u16 = null,

// __DWARF segment sections
dwarf_debug_info_index: ?u16 = null,
dwarf_debug_abbrev_index: ?u16 = null,
dwarf_debug_str_index: ?u16 = null,
dwarf_debug_line_index: ?u16 = null,
dwarf_debug_line_str_index: ?u16 = null,
dwarf_debug_ranges_index: ?u16 = null,

symtab: std.ArrayListUnmanaged(macho.nlist_64) = .{},
strtab: []const u8 = &.{},
data_in_code_entries: []const macho.data_in_code_entry = &.{},

// Debug info
debug_info: ?DebugInfo = null,
tu_name: ?[]const u8 = null,
tu_comp_dir: ?[]const u8 = null,
mtime: ?u64 = null,

sections_as_symbols: std.AutoHashMapUnmanaged(u16, u32) = .{},

/// List of atoms that map to the symbols parsed from this object file.
managed_atoms: std.ArrayListUnmanaged(*Atom) = .{},

/// Table of atoms belonging to this object file indexed by the symbol index.
atom_by_index_table: std.AutoHashMapUnmanaged(u32, *Atom) = .{},

const DebugInfo = struct {
    inner: dwarf.DwarfInfo,
    debug_info: []const u8,
    debug_abbrev: []const u8,
    debug_str: []const u8,
    debug_line: []const u8,
    debug_line_str: []const u8,
    debug_ranges: []const u8,

    pub fn parseFromObject(allocator: Allocator, object: *const Object) !?DebugInfo {
        var debug_info = blk: {
            const index = object.dwarf_debug_info_index orelse return null;
            break :blk object.getSectionContents(index);
        };
        var debug_abbrev = blk: {
            const index = object.dwarf_debug_abbrev_index orelse return null;
            break :blk object.getSectionContents(index);
        };
        var debug_str = blk: {
            const index = object.dwarf_debug_str_index orelse return null;
            break :blk object.getSectionContents(index);
        };
        var debug_line = blk: {
            const index = object.dwarf_debug_line_index orelse return null;
            break :blk object.getSectionContents(index);
        };
        var debug_line_str = blk: {
            if (object.dwarf_debug_line_str_index) |ind| {
                break :blk object.getSectionContents(ind);
            }
            break :blk &[0]u8{};
        };
        var debug_ranges = blk: {
            if (object.dwarf_debug_ranges_index) |ind| {
                break :blk object.getSectionContents(ind);
            }
            break :blk &[0]u8{};
        };

        var inner: dwarf.DwarfInfo = .{
            .endian = .Little,
            .debug_info = debug_info,
            .debug_abbrev = debug_abbrev,
            .debug_str = debug_str,
            .debug_line = debug_line,
            .debug_line_str = debug_line_str,
            .debug_ranges = debug_ranges,
        };
        try dwarf.openDwarfDebugInfo(&inner, allocator);

        return DebugInfo{
            .inner = inner,
            .debug_info = debug_info,
            .debug_abbrev = debug_abbrev,
            .debug_str = debug_str,
            .debug_line = debug_line,
            .debug_line_str = debug_line_str,
            .debug_ranges = debug_ranges,
        };
    }

    pub fn deinit(self: *DebugInfo, allocator: Allocator) void {
        self.inner.deinit(allocator);
    }
};

pub fn deinit(self: *Object, gpa: Allocator) void {
    for (self.load_commands.items) |*lc| {
        lc.deinit(gpa);
    }
    self.load_commands.deinit(gpa);
    gpa.free(self.contents);
    self.sections_as_symbols.deinit(gpa);
    self.atom_by_index_table.deinit(gpa);

    for (self.managed_atoms.items) |atom| {
        atom.deinit(gpa);
        gpa.destroy(atom);
    }
    self.managed_atoms.deinit(gpa);

    gpa.free(self.name);

    if (self.debug_info) |*db| {
        db.deinit(gpa);
    }
}

pub fn parse(self: *Object, allocator: Allocator, target: std.Target) !void {
    const file_stat = try self.file.stat();
    const file_size = math.cast(usize, file_stat.size) orelse return error.Overflow;
    self.contents = try self.file.readToEndAlloc(allocator, file_size);

    var stream = std.io.fixedBufferStream(self.contents);
    const reader = stream.reader();

    const file_offset = self.file_offset orelse 0;
    if (file_offset > 0) {
        try reader.context.seekTo(file_offset);
    }

    self.header = try reader.readStruct(macho.mach_header_64);
    if (self.header.filetype != macho.MH_OBJECT) {
        log.warn("invalid filetype: expected 0x{x}, found 0x{x}", .{
            macho.MH_OBJECT,
            self.header.filetype,
        });
        return error.NotObject;
    }

    const this_arch: std.Target.Cpu.Arch = switch (self.header.cputype) {
        macho.CPU_TYPE_ARM64 => .aarch64,
        macho.CPU_TYPE_X86_64 => .x86_64,
        else => |value| {
            log.err("unsupported cpu architecture 0x{x}", .{value});
            return error.UnsupportedCpuArchitecture;
        },
    };
    if (this_arch != target.cpu.arch) {
        log.err("mismatched cpu architecture: expected {s}, found {s}", .{ target.cpu.arch, this_arch });
        return error.MismatchedCpuArchitecture;
    }

    try self.load_commands.ensureUnusedCapacity(allocator, self.header.ncmds);

    var i: u16 = 0;
    while (i < self.header.ncmds) : (i += 1) {
        var cmd = try macho.LoadCommand.read(allocator, reader);
        switch (cmd.cmd()) {
            .SEGMENT_64 => {
                self.segment_cmd_index = i;
                var seg = cmd.segment;
                for (seg.sections.items) |*sect, j| {
                    const index = @intCast(u16, j);
                    const segname = sect.segName();
                    const sectname = sect.sectName();
                    if (mem.eql(u8, segname, "__DWARF")) {
                        if (mem.eql(u8, sectname, "__debug_info")) {
                            self.dwarf_debug_info_index = index;
                        } else if (mem.eql(u8, sectname, "__debug_abbrev")) {
                            self.dwarf_debug_abbrev_index = index;
                        } else if (mem.eql(u8, sectname, "__debug_str")) {
                            self.dwarf_debug_str_index = index;
                        } else if (mem.eql(u8, sectname, "__debug_line")) {
                            self.dwarf_debug_line_index = index;
                        } else if (mem.eql(u8, sectname, "__debug_line_str")) {
                            self.dwarf_debug_line_str_index = index;
                        } else if (mem.eql(u8, sectname, "__debug_ranges")) {
                            self.dwarf_debug_ranges_index = index;
                        }
                    } else if (mem.eql(u8, segname, "__TEXT")) {
                        if (mem.eql(u8, sectname, "__text")) {
                            self.text_section_index = index;
                        }
                    }

                    sect.offset += file_offset;
                    if (sect.reloff > 0) {
                        sect.reloff += file_offset;
                    }
                }

                seg.inner.fileoff += file_offset;
            },
            .SYMTAB => {
                self.symtab_cmd_index = i;
                cmd.symtab.symoff += file_offset;
                cmd.symtab.stroff += file_offset;
            },
            .DYSYMTAB => {
                self.dysymtab_cmd_index = i;
            },
            .BUILD_VERSION => {
                self.build_version_cmd_index = i;
            },
            .DATA_IN_CODE => {
                self.data_in_code_cmd_index = i;
                cmd.linkedit_data.dataoff += file_offset;
            },
            else => {
                log.warn("Unknown load command detected: 0x{x}.", .{cmd.cmd()});
            },
        }
        self.load_commands.appendAssumeCapacity(cmd);
    }

    try self.parseSymtab(allocator);
    self.parseDataInCode();
    try self.parseDebugInfo(allocator);
}

const SymbolAtIndex = struct {
    index: u32,

    fn getSymbol(self: SymbolAtIndex, object: *Object) macho.nlist_64 {
        return self.getSymbolPtr(object).*;
    }

    fn getSymbolPtr(self: SymbolAtIndex, object: *Object) *macho.nlist_64 {
        return &object.symtab.items[self.index];
    }

    fn getSymbolName(self: SymbolAtIndex, object: *Object) []const u8 {
        const sym = self.getSymbol(object);
        return if (sym.n_strx == 0) "" else object.getString(sym.n_strx);
    }

    const SortContext = struct {
        object: *Object,
    };

    fn lessThan(ctx: SortContext, lhs_index: SymbolAtIndex, rhs_index: SymbolAtIndex) bool {
        // We sort by type: defined < undefined, and
        // afterwards by address in each group. Normally, dysymtab should
        // be enough to guarantee the sort, but turns out not every compiler
        // is kind enough to specify the symbols in the correct order.
        const lhs = lhs_index.getSymbol(ctx.object);
        const rhs = rhs_index.getSymbol(ctx.object);
        if (lhs.sect()) {
            if (rhs.sect()) {
                // Same group, sort by address.
                return lhs.n_value < rhs.n_value;
            } else {
                return true;
            }
        } else {
            return false;
        }
    }
};

fn filterSymbolsByAddress(
    self: *Object,
    indexes: []SymbolAtIndex,
    start_addr: u64,
    end_addr: u64,
) []SymbolAtIndex {
    const Predicate = struct {
        addr: u64,
        object: *Object,

        pub fn predicate(pred: @This(), index: SymbolAtIndex) bool {
            return index.getSymbol(pred.object).n_value >= pred.addr;
        }
    };

    const start = MachO.findFirst(SymbolAtIndex, indexes, 0, Predicate{
        .addr = start_addr,
        .object = self,
    });
    const end = MachO.findFirst(SymbolAtIndex, indexes, start, Predicate{
        .addr = end_addr,
        .object = self,
    });

    return indexes[start..end];
}

fn filterRelocs(
    relocs: []const macho.relocation_info,
    start_addr: u64,
    end_addr: u64,
) []const macho.relocation_info {
    const Predicate = struct {
        addr: u64,

        pub fn predicate(self: @This(), rel: macho.relocation_info) bool {
            return rel.r_address < self.addr;
        }
    };

    const start = MachO.findFirst(macho.relocation_info, relocs, 0, Predicate{ .addr = end_addr });
    const end = MachO.findFirst(macho.relocation_info, relocs, start, Predicate{ .addr = start_addr });

    return relocs[start..end];
}

fn filterDice(
    dices: []const macho.data_in_code_entry,
    start_addr: u64,
    end_addr: u64,
) []const macho.data_in_code_entry {
    const Predicate = struct {
        addr: u64,

        pub fn predicate(self: @This(), dice: macho.data_in_code_entry) bool {
            return dice.offset >= self.addr;
        }
    };

    const start = MachO.findFirst(macho.data_in_code_entry, dices, 0, Predicate{ .addr = start_addr });
    const end = MachO.findFirst(macho.data_in_code_entry, dices, start, Predicate{ .addr = end_addr });

    return dices[start..end];
}

/// Splits object into atoms assuming whole cache mode aka traditional linking mode.
pub fn splitIntoAtomsWhole(self: *Object, macho_file: *MachO, object_id: u32) !void {
    const tracy = trace(@src());
    defer tracy.end();

    const gpa = macho_file.base.allocator;
    const seg = self.load_commands.items[self.segment_cmd_index.?].segment;

    log.warn("splitting object({d}, {s}) into atoms: whole cache mode", .{ object_id, self.name });

    // You would expect that the symbol table is at least pre-sorted based on symbol's type:
    // local < extern defined < undefined. Unfortunately, this is not guaranteed! For instance,
    // the GO compiler does not necessarily respect that therefore we sort immediately by type
    // and address within.
    var sorted_all_syms = try std.ArrayList(SymbolAtIndex).initCapacity(gpa, self.symtab.items.len);
    defer sorted_all_syms.deinit();

    for (self.symtab.items) |_, index| {
        sorted_all_syms.appendAssumeCapacity(.{ .index = @intCast(u32, index) });
    }

    sort.sort(
        SymbolAtIndex,
        sorted_all_syms.items,
        SymbolAtIndex.SortContext{ .object = self },
        SymbolAtIndex.lessThan,
    );

    // Well, shit, sometimes compilers skip the dysymtab load command altogether, meaning we
    // have to infer the start of undef section in the symtab ourselves.
    const iundefsym = if (self.dysymtab_cmd_index) |cmd_index| blk: {
        const dysymtab = self.load_commands.items[cmd_index].dysymtab;
        break :blk dysymtab.iundefsym;
    } else blk: {
        var iundefsym: usize = sorted_all_syms.items.len;
        while (iundefsym > 0) : (iundefsym -= 1) {
            const sym = sorted_all_syms.items[iundefsym - 1].getSymbol(self);
            if (sym.sect()) break;
        }
        break :blk iundefsym;
    };

    // We only care about defined symbols, so filter every other out.
    const sorted_syms = sorted_all_syms.items[0..iundefsym];
    const dead_strip = macho_file.base.options.gc_sections orelse false;
    const subsections_via_symbols = self.header.flags & macho.MH_SUBSECTIONS_VIA_SYMBOLS != 0 and
        (macho_file.base.options.optimize_mode != .Debug or dead_strip);

    for (seg.sections.items) |sect, id| {
        const sect_id = @intCast(u8, id);
        log.warn("splitting section '{s},{s}' into atoms", .{ sect.segName(), sect.sectName() });

        // Get matching segment/section in the final artifact.
        const match = (try macho_file.getMatchingSection(sect)) orelse {
            log.warn("  unhandled section", .{});
            continue;
        };
        const target_sect = macho_file.getSection(match);
        log.warn("  output section '{s},{s}'", .{ target_sect.segName(), target_sect.sectName() });

        const is_zerofill = blk: {
            const section_type = sect.type_();
            break :blk section_type == macho.S_ZEROFILL or section_type == macho.S_THREAD_LOCAL_ZEROFILL;
        };

        // Read section's code
        const code: ?[]const u8 = if (!is_zerofill) self.getSectionContents(sect_id) else null;

        // Read section's list of relocations
        const raw_relocs = self.contents[sect.reloff..][0 .. sect.nreloc * @sizeOf(macho.relocation_info)];
        const relocs = mem.bytesAsSlice(
            macho.relocation_info,
            @alignCast(@alignOf(macho.relocation_info), raw_relocs),
        );

        // Symbols within this section only.
        const filtered_syms = self.filterSymbolsByAddress(
            sorted_syms,
            sect.addr,
            sect.addr + sect.size,
        );

        macho_file.has_dices = macho_file.has_dices or blk: {
            if (self.text_section_index) |index| {
                if (index != id) break :blk false;
                if (self.data_in_code_entries.len == 0) break :blk false;
                break :blk true;
            }
            break :blk false;
        };
        macho_file.has_stabs = macho_file.has_stabs or self.debug_info != null;

        if (subsections_via_symbols and filtered_syms.len > 0) {
            // If the first nlist does not match the start of the section,
            // then we need to encapsulate the memory range [section start, first symbol)
            // as a temporary symbol and insert the matching Atom.
            const first_sym = filtered_syms[0].getSymbol(self);
            if (first_sym.n_value > sect.addr) {
                const sym_index = self.sections_as_symbols.get(sect_id) orelse blk: {
                    const sym_index = @intCast(u32, self.symtab.items.len);
                    try self.symtab.append(gpa, .{
                        .n_strx = 0,
                        .n_type = macho.N_SECT,
                        .n_sect = @intCast(u8, macho_file.section_ordinals.getIndex(match).? + 1),
                        .n_desc = 0,
                        .n_value = sect.addr,
                    });
                    try self.sections_as_symbols.putNoClobber(gpa, sect_id, sym_index);
                    break :blk sym_index;
                };
                const atom_size = first_sym.n_value - sect.addr;
                const atom_code: ?[]const u8 = if (code) |cc|
                    cc[0..atom_size]
                else
                    null;
                const atom = try self.createAtomFromSubsection(
                    macho_file,
                    object_id,
                    sym_index,
                    atom_size,
                    sect.@"align",
                    atom_code,
                    relocs,
                    &.{},
                    match,
                    sect,
                );
                try macho_file.addAtomToSection(atom, match);
            }

            var next_sym_count: usize = 0;
            while (next_sym_count < filtered_syms.len) {
                const next_sym = filtered_syms[next_sym_count].getSymbol(self);
                const addr = next_sym.n_value;
                const atom_syms = self.filterSymbolsByAddress(
                    filtered_syms[next_sym_count..],
                    addr,
                    addr + 1,
                );
                next_sym_count += atom_syms.len;

                assert(atom_syms.len > 0);
                const sym_index = atom_syms[0].index;
                const atom_size = blk: {
                    const end_addr = if (next_sym_count < filtered_syms.len)
                        filtered_syms[next_sym_count].getSymbol(self).n_value
                    else
                        sect.addr + sect.size;
                    break :blk end_addr - addr;
                };
                const atom_code: ?[]const u8 = if (code) |cc|
                    cc[addr - sect.addr ..][0..atom_size]
                else
                    null;
                const atom_align = if (addr > 0)
                    math.min(@ctz(u64, addr), sect.@"align")
                else
                    sect.@"align";
                const atom = try self.createAtomFromSubsection(
                    macho_file,
                    object_id,
                    sym_index,
                    atom_size,
                    atom_align,
                    atom_code,
                    relocs,
                    atom_syms[1..],
                    match,
                    sect,
                );
                try macho_file.addAtomToSection(atom, match);
            }
        } else {
            // If there is no symbol to refer to this atom, we create
            // a temp one, unless we already did that when working out the relocations
            // of other atoms.
            const sym_index = self.sections_as_symbols.get(sect_id) orelse blk: {
                const sym_index = @intCast(u32, self.symtab.items.len);
                try self.symtab.append(gpa, .{
                    .n_strx = 0,
                    .n_type = macho.N_SECT,
                    .n_sect = @intCast(u8, macho_file.section_ordinals.getIndex(match).? + 1),
                    .n_desc = 0,
                    .n_value = sect.addr,
                });
                try self.sections_as_symbols.putNoClobber(gpa, sect_id, sym_index);
                break :blk sym_index;
            };
            const atom = try self.createAtomFromSubsection(
                macho_file,
                object_id,
                sym_index,
                sect.size,
                sect.@"align",
                code,
                relocs,
                filtered_syms,
                match,
                sect,
            );
            try macho_file.addAtomToSection(atom, match);
        }
    }
}

fn createAtomFromSubsection(
    self: *Object,
    macho_file: *MachO,
    object_id: u32,
    sym_index: u32,
    size: u64,
    alignment: u32,
    code: ?[]const u8,
    relocs: []const macho.relocation_info,
    indexes: []const SymbolAtIndex,
    match: MatchingSection,
    sect: macho.section_64,
) !*Atom {
    const gpa = macho_file.base.allocator;
    const sym = &self.symtab.items[sym_index];
    const align_pow_2 = try math.powi(u32, 2, alignment);
    const aligned_size = mem.alignForwardGeneric(u64, size, align_pow_2);
    const atom = try MachO.createEmptyAtom(gpa, sym_index, aligned_size, alignment);
    atom.file = object_id;
    sym.n_sect = @intCast(u8, macho_file.section_ordinals.getIndex(match).? + 1);

    try self.atom_by_index_table.putNoClobber(gpa, sym_index, atom);
    try self.managed_atoms.append(gpa, atom);

    if (code) |cc| {
        mem.copy(u8, atom.code.items, cc);
    }

    const base_offset = sym.n_value - sect.addr;
    const filtered_relocs = filterRelocs(relocs, base_offset, base_offset + size);
    try atom.parseRelocs(filtered_relocs, .{
        .macho_file = macho_file,
        .base_addr = sect.addr,
        .base_offset = @intCast(i32, base_offset),
    });

    if (macho_file.has_dices) {
        const dices = filterDice(self.data_in_code_entries, sym.n_value, sym.n_value + size);
        try atom.dices.ensureTotalCapacity(gpa, dices.len);

        for (dices) |dice| {
            atom.dices.appendAssumeCapacity(.{
                .offset = dice.offset - (math.cast(u32, sym.n_value) orelse return error.Overflow),
                .length = dice.length,
                .kind = dice.kind,
            });
        }
    }

    // Since this is atom gets a helper local temporary symbol that didn't exist
    // in the object file which encompasses the entire section, we need traverse
    // the filtered symbols and note which symbol is contained within so that
    // we can properly allocate addresses down the line.
    // While we're at it, we need to update segment,section mapping of each symbol too.
    try atom.contained.ensureTotalCapacity(gpa, indexes.len);

    for (indexes) |inner_sym_index| {
        const inner_sym = inner_sym_index.getSymbolPtr(self);
        inner_sym.n_sect = @intCast(u8, macho_file.section_ordinals.getIndex(match).? + 1);

        const stab: ?Atom.Stab = if (self.debug_info) |di| blk: {
            // TODO there has to be a better to handle this.
            for (di.inner.func_list.items) |func| {
                if (func.pc_range) |range| {
                    if (inner_sym.n_value >= range.start and inner_sym.n_value < range.end) {
                        break :blk Atom.Stab{
                            .function = range.end - range.start,
                        };
                    }
                }
            }
            // TODO
            // if (zld.globals.contains(zld.getString(sym.strx))) break :blk .global;
            break :blk .static;
        } else null;

        atom.contained.appendAssumeCapacity(.{
            .sym_index = inner_sym_index.index,
            .offset = inner_sym.n_value - sym.n_value,
            .stab = stab,
        });

        try self.atom_by_index_table.putNoClobber(gpa, inner_sym_index.index, atom);
    }

    const is_gc_root = blk: {
        if (sect.isDontDeadStrip()) break :blk true;
        if (sect.isDontDeadStripIfReferencesLive()) {
            // TODO if isDontDeadStripIfReferencesLive we should analyse the edges
            // before making it a GC root
            break :blk true;
        }
        if (mem.eql(u8, "__StaticInit", sect.sectName())) break :blk true;
        switch (sect.type_()) {
            macho.S_MOD_INIT_FUNC_POINTERS,
            macho.S_MOD_TERM_FUNC_POINTERS,
            => break :blk true,
            else => break :blk false,
        }
    };
    if (is_gc_root) {
        try macho_file.gc_roots.putNoClobber(gpa, atom, {});
    }

    return atom;
}

fn parseSymtab(self: *Object, allocator: Allocator) !void {
    const index = self.symtab_cmd_index orelse return;
    const symtab = self.load_commands.items[index].symtab;
    const symtab_size = @sizeOf(macho.nlist_64) * symtab.nsyms;
    const raw_symtab = self.contents[symtab.symoff..][0..symtab_size];
    try self.symtab.appendSlice(allocator, mem.bytesAsSlice(
        macho.nlist_64,
        @alignCast(@alignOf(macho.nlist_64), raw_symtab),
    ));
    self.strtab = self.contents[symtab.stroff..][0..symtab.strsize];
}

fn parseDebugInfo(self: *Object, allocator: Allocator) !void {
    log.warn("parsing debug info in '{s}'", .{self.name});

    var debug_info = blk: {
        var di = try DebugInfo.parseFromObject(allocator, self);
        break :blk di orelse return;
    };

    // We assume there is only one CU.
    const compile_unit = debug_info.inner.findCompileUnit(0x0) catch |err| switch (err) {
        error.MissingDebugInfo => {
            // TODO audit cases with missing debug info and audit our dwarf.zig module.
            log.warn("invalid or missing debug info in {s}; skipping", .{self.name});
            return;
        },
        else => |e| return e,
    };
    const name = try compile_unit.die.getAttrString(&debug_info.inner, dwarf.AT.name);
    const comp_dir = try compile_unit.die.getAttrString(&debug_info.inner, dwarf.AT.comp_dir);

    self.debug_info = debug_info;
    self.tu_name = name;
    self.tu_comp_dir = comp_dir;

    if (self.mtime == null) {
        self.mtime = mtime: {
            const stat = self.file.stat() catch break :mtime 0;
            break :mtime @intCast(u64, @divFloor(stat.mtime, 1_000_000_000));
        };
    }
}

fn parseDataInCode(self: *Object) void {
    const index = self.data_in_code_cmd_index orelse return;
    const data_in_code = self.load_commands.items[index].linkedit_data;
    const raw_dice = self.contents[data_in_code.dataoff..][0..data_in_code.datasize];
    self.data_in_code_entries = mem.bytesAsSlice(
        macho.data_in_code_entry,
        @alignCast(@alignOf(macho.data_in_code_entry), raw_dice),
    );
}

fn getSectionContents(self: Object, sect_id: u16) []const u8 {
    const sect = self.getSection(sect_id);
    log.warn("getting {s},{s} data at 0x{x} - 0x{x}", .{
        sect.segName(),
        sect.sectName(),
        sect.offset,
        sect.offset + sect.size,
    });
    return self.contents[sect.offset..][0..sect.size];
}

pub fn getString(self: Object, off: u32) []const u8 {
    assert(off < self.strtab.len);
    return mem.sliceTo(@ptrCast([*:0]const u8, self.strtab.ptr + off), 0);
}

pub fn getSection(self: Object, n_sect: u16) macho.section_64 {
    const seg = self.load_commands.items[self.segment_cmd_index.?].segment;
    assert(n_sect < seg.sections.items.len);
    return seg.sections.items[n_sect];
}
