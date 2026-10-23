# GDB pretty-printers for Odin types. Loaded by `build debug`, or manually:
#   (gdb) source tools/debugger/odin_gdb.py
#
#   string            "text"
#   []T, [dynamic]T   their elements (len/cap in the summary)
#   map[K]V           its key/value pairs
#   union             only the active variant (or nil)
#   vulkan handles    hex, not mis-decoded as C strings
#
# Map layout mirrors base/runtime/dynamic_map_internal.odin: the data pointer
# carries log2(slot count) in its low 6 bits; keys, values and hashes follow
# each other, packed into 64-byte cells; a slot is live when its hash is
# non-zero and the top (tombstone) bit is clear.

import gdb

MAX_ITEMS = 200
MAX_STRING = 400
CACHE_LINE = 64


def odin_string(val):
    n = int(val["len"])
    data = val["data"]
    if n == 0 or int(data) == 0:
        return '""'
    text = data.string(encoding="utf-8", errors="replace", length=min(n, MAX_STRING))
    return '"%s%s"' % (text, "..." if n > MAX_STRING else "")


class StringPrinter:
    def __init__(self, val):
        self.val = val

    def to_string(self):
        return odin_string(self.val)


class SlicePrinter:
    def __init__(self, val, dynamic):
        self.val = val
        self.dynamic = dynamic

    def to_string(self):
        if self.dynamic:
            return "len=%d cap=%d" % (int(self.val["len"]), int(self.val["cap"]))
        return "len=%d" % int(self.val["len"])

    def children(self):
        data = self.val["data"]
        for i in range(min(int(self.val["len"]), MAX_ITEMS)):
            yield "[%d]" % i, (data + i).dereference()

    def display_hint(self):
        return "array"


def map_element_address(base, index, size):
    per_cell = CACHE_LINE // size if 0 < size < CACHE_LINE else 1
    cell_size = -(-(per_cell * size) // CACHE_LINE) * CACHE_LINE  # round up to 64
    return base + (index // per_cell) * cell_size + (index % per_cell) * size


class MapPrinter:
    def __init__(self, val):
        self.val = val

    def to_string(self):
        return "len=%d" % int(self.val["len"])

    def children(self):
        raw = int(self.val["data"].cast(gdb.lookup_type("unsigned long")))
        if raw == 0 or int(self.val["len"]) == 0:
            return
        slots = 1 << (raw & (CACHE_LINE - 1))
        keys = raw & ~(CACHE_LINE - 1)
        cell = self.val["data"].type.target()
        key_t, value_t = cell["key"].type, cell["value"].type
        values = map_element_address(keys, slots, key_t.sizeof)
        hashes = map_element_address(values, slots, value_t.sizeof)
        hash_t = gdb.lookup_type("unsigned long")
        shown = 0
        for i in range(slots):
            h = int(gdb.Value(hashes + i * 8).cast(hash_t.pointer()).dereference())
            if h == 0 or h & (1 << 63):
                continue
            k = gdb.Value(map_element_address(keys, i, key_t.sizeof)).cast(key_t.pointer()).dereference()
            v = gdb.Value(map_element_address(values, i, value_t.sizeof)).cast(value_t.pointer()).dereference()
            yield "key", k
            yield "value", v
            shown += 1
            if shown >= MAX_ITEMS:
                return

    def display_hint(self):
        return "map"


class UnionPrinter:
    def __init__(self, val):
        self.val = val
        self.tag = int(val["tag"])

    def to_string(self):
        if self.tag == 0:
            return "nil"
        return str(self.val["v%d" % self.tag].type)

    def children(self):
        if self.tag == 0:
            return
        variant = self.val["v%d" % self.tag]
        if variant.type.strip_typedefs().code == gdb.TYPE_CODE_STRUCT:
            for field in variant.type.strip_typedefs().fields():
                yield field.name, variant[field.name]
        else:
            yield "value", variant


class HandlePrinter:
    def __init__(self, val):
        self.val = val

    def to_string(self):
        return "0x%x" % int(self.val.cast(gdb.lookup_type("unsigned long")))


def is_odin_union(t):
    if t.code != gdb.TYPE_CODE_UNION:
        return False
    names = [f.name for f in t.fields()]
    return len(names) >= 2 and names[0] == "tag" and all(n == "v%d" % i for i, n in enumerate(names[1:], 1))


def lookup(val):
    t = val.type
    name = t.name or ""
    if name.startswith("vulkan::") and t.strip_typedefs().code == gdb.TYPE_CODE_PTR:
        return HandlePrinter(val)
    t = t.strip_typedefs()
    tag = t.tag or t.name or ""
    if tag == "string":
        return StringPrinter(val)
    if tag.startswith("[]"):
        return SlicePrinter(val, False)
    if tag.startswith("[dynamic]"):
        return SlicePrinter(val, True)
    if tag.startswith("map["):
        return MapPrinter(val)
    if is_odin_union(t):
        return UnionPrinter(val)
    return None


gdb.pretty_printers.append(lookup)
gdb.execute("set print pretty on")
gdb.execute("set debuginfod enabled off")
print("odin pretty-printers loaded")
