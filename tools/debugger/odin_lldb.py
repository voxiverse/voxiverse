# LLDB formatters for Odin types (the same set as odin_gdb.py). Loaded by
# `build debug --lldb`, or manually:
#   (lldb) command script import tools/debugger/odin_lldb.py
#
# Map layout mirrors base/runtime/dynamic_map_internal.odin; see odin_gdb.py.

import lldb

MAX_ITEMS = 200
MAX_STRING = 400
CACHE_LINE = 64


def _read_string(valobj):
    n = valobj.GetChildMemberWithName("len").GetValueAsSigned()
    data = valobj.GetChildMemberWithName("data").GetValueAsUnsigned()
    if n <= 0 or data == 0:
        return '""'
    err = lldb.SBError()
    raw = valobj.GetProcess().ReadMemory(data, min(n, MAX_STRING), err)
    if not err.Success():
        return "<unreadable>"
    return '"%s%s"' % (raw.decode("utf-8", "replace"), "..." if n > MAX_STRING else "")


def string_summary(valobj, internal_dict):
    return _read_string(valobj.GetNonSyntheticValue())


def slice_summary(valobj, internal_dict):
    v = valobj.GetNonSyntheticValue()
    return "len=%d" % v.GetChildMemberWithName("len").GetValueAsSigned()


def dynamic_summary(valobj, internal_dict):
    v = valobj.GetNonSyntheticValue()
    return "len=%d cap=%d" % (
        v.GetChildMemberWithName("len").GetValueAsSigned(),
        v.GetChildMemberWithName("cap").GetValueAsSigned(),
    )


class SliceProvider:
    def __init__(self, valobj, internal_dict):
        self.valobj = valobj

    def update(self):
        data = self.valobj.GetChildMemberWithName("data")
        self.base = data.GetValueAsUnsigned()
        self.elem = data.GetType().GetPointeeType()
        self.size = self.elem.GetByteSize()
        self.count = min(max(self.valobj.GetChildMemberWithName("len").GetValueAsSigned(), 0), MAX_ITEMS)
        return False

    def num_children(self):
        return self.count

    def get_child_index(self, name):
        try:
            return int(name.strip("[]"))
        except ValueError:
            return -1

    def get_child_at_index(self, index):
        return self.valobj.CreateValueFromAddress("[%d]" % index, self.base + index * self.size, self.elem)

    def has_children(self):
        return True


def _map_element_address(base, index, size):
    per_cell = CACHE_LINE // size if 0 < size < CACHE_LINE else 1
    cell_size = -(-(per_cell * size) // CACHE_LINE) * CACHE_LINE
    return base + (index // per_cell) * cell_size + (index % per_cell) * size


def map_summary(valobj, internal_dict):
    return "len=%d" % valobj.GetNonSyntheticValue().GetChildMemberWithName("len").GetValueAsSigned()


class MapProvider:
    """Children are the live values, each named after its key."""

    def __init__(self, valobj, internal_dict):
        self.valobj = valobj

    def update(self):
        self.entries = []
        data = self.valobj.GetChildMemberWithName("data")
        raw = data.GetValueAsUnsigned()
        if raw == 0 or self.valobj.GetChildMemberWithName("len").GetValueAsSigned() == 0:
            return False
        slots = 1 << (raw & (CACHE_LINE - 1))
        keys = raw & ~(CACHE_LINE - 1)
        cell = data.GetType().GetPointeeType()
        key_t = cell.GetFieldAtIndex(0).GetType()
        value_t = cell.GetFieldAtIndex(1).GetType()
        values = _map_element_address(keys, slots, key_t.GetByteSize())
        hashes = _map_element_address(values, slots, value_t.GetByteSize())
        process = self.valobj.GetProcess()
        err = lldb.SBError()
        for i in range(slots):
            h = process.ReadUnsignedFromMemory(hashes + i * 8, 8, err)
            if not err.Success() or h == 0 or h & (1 << 63):
                continue
            key = self.valobj.CreateValueFromAddress("key", _map_element_address(keys, i, key_t.GetByteSize()), key_t)
            label = key.GetSummary() or key.GetValue() or ("#%d" % i)
            self.entries.append((label, _map_element_address(values, i, value_t.GetByteSize()), value_t))
            if len(self.entries) >= MAX_ITEMS:
                break
        return False

    def num_children(self):
        return len(self.entries)

    def get_child_index(self, name):
        for i, entry in enumerate(self.entries):
            if "[%s]" % entry[0] == name:
                return i
        return -1

    def get_child_at_index(self, index):
        label, address, value_t = self.entries[index]
        return self.valobj.CreateValueFromAddress("[%s]" % label, address, value_t)

    def has_children(self):
        return True


def _is_union(sbtype):
    t = sbtype.GetCanonicalType()
    if t.GetTypeClass() != lldb.eTypeClassUnion or t.GetNumberOfFields() < 2:
        return False
    names = [t.GetFieldAtIndex(i).GetName() for i in range(t.GetNumberOfFields())]
    return names[0] == "tag" and all(n == "v%d" % i for i, n in enumerate(names[1:], 1))


def is_union(sbtype, internal_dict):
    return _is_union(sbtype)


def _active_variant(valobj):
    v = valobj.GetNonSyntheticValue()
    tag = v.GetChildMemberWithName("tag").GetValueAsUnsigned()
    return None if tag == 0 else v.GetChildMemberWithName("v%d" % tag)


def union_summary(valobj, internal_dict):
    variant = _active_variant(valobj)
    return "nil" if variant is None else variant.GetTypeName()


class UnionProvider:
    def __init__(self, valobj, internal_dict):
        self.valobj = valobj

    def update(self):
        self.variant = _active_variant(self.valobj)
        return False

    def num_children(self):
        return 0 if self.variant is None else self.variant.GetNumChildren()

    def get_child_index(self, name):
        return -1 if self.variant is None else self.variant.GetIndexOfChildWithName(name)

    def get_child_at_index(self, index):
        return self.variant.GetChildAtIndex(index)

    def has_children(self):
        return self.variant is not None


def is_vulkan_handle(sbtype, internal_dict):
    return sbtype.GetName().startswith("vulkan::") and sbtype.GetCanonicalType().IsPointerType()


def handle_summary(valobj, internal_dict):
    return "0x%x" % valobj.GetValueAsUnsigned()


def __lldb_init_module(debugger, internal_dict):
    m = __name__
    for command in (
        "type summary add -w odin -F %s.string_summary string" % m,
        "type summary add -w odin -e -x '^\\[\\]' -F %s.slice_summary" % m,
        "type synthetic add -w odin -x '^\\[\\]' -l %s.SliceProvider" % m,
        "type summary add -w odin -e -x '^\\[dynamic\\]' -F %s.dynamic_summary" % m,
        "type synthetic add -w odin -x '^\\[dynamic\\]' -l %s.SliceProvider" % m,
        "type summary add -w odin -e -x '^map\\[' -F %s.map_summary" % m,
        "type synthetic add -w odin -x '^map\\[' -l %s.MapProvider" % m,
        "type summary add -w odin -e --recognizer-function %s.is_union -F %s.union_summary" % (m, m),
        "type synthetic add -w odin --recognizer-function %s.is_union -l %s.UnionProvider" % (m, m),
        "type summary add -w odin --recognizer-function %s.is_vulkan_handle -F %s.handle_summary" % (m, m),
        "type category enable odin",
    ):
        debugger.HandleCommand(command)
    print("odin formatters loaded")
