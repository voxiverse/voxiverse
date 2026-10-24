package game

// Items: what players carry. Every block players may place has its item;
// tools are items of their own. An item's id is on the wire; saves use its
// name. Ids are append-only like blocks': a block's item is its block id
// + 1 (0 is no item), a tool's TOOL_ITEMS + its tool id.

Item :: distinct u16

NO_ITEM :: Item(0)
TOOL_ITEMS :: Item(0x8000)

Tool :: enum u8 {
	Launcher, // fires rockets (world.fire)
}

Item_Info :: struct {
	name:  string,
	stack: int, // how many one slot holds
	block: Block, // what it places (Air: nothing)
	tool:  Maybe(Tool),
}

@(rodata)
TOOL_INFO := [Tool]Item_Info {
	.Launcher = {name = "rocket_launcher", stack = 1, tool = .Launcher},
}

BLOCK_STACK :: 64

item_of_block :: proc(b: Block) -> Item {
	if !BLOCK_INFO[b].placeable {return NO_ITEM}
	return Item(u16(b) + 1)
}

item_of_tool :: proc(t: Tool) -> Item {
	return TOOL_ITEMS + Item(t)
}

// item_info: what item i is; false if it is no item (or not one we know).
item_info :: proc(i: Item) -> (Item_Info, bool) {
	switch {
	case i == NO_ITEM:
		return {}, false
	case i >= TOOL_ITEMS:
		t := int(i - TOOL_ITEMS)
		if t >= len(Tool) {return {}, false}
		return TOOL_INFO[Tool(t)], true
	}
	id := u16(i) - 1
	if !block_valid(id) || !BLOCK_INFO[Block(id)].placeable {return {}, false}
	b := Block(id)
	return {name = BLOCK_INFO[b].name, stack = BLOCK_STACK, block = b}, true
}

item_valid :: proc(i: Item) -> bool {
	_, ok := item_info(i)
	return ok
}

item_name :: proc(i: Item) -> string {
	info, _ := item_info(i)
	return info.name
}

item_stack_size :: proc(i: Item) -> int {
	info, _ := item_info(i)
	return info.stack
}

// item_by_name: the item called name ("stone", "rocket_launcher").
item_by_name :: proc(name: string) -> (Item, bool) {
	for t in Tool {if TOOL_INFO[t].name == name {return item_of_tool(t), true}}
	if b, ok := block_by_name(name); ok && BLOCK_INFO[b].placeable {return item_of_block(b), true}
	return NO_ITEM, false
}

// every_item: all the items there are, in a stable order (blocks, tools).
every_item :: proc(allocator := context.temp_allocator) -> []Item {
	items := make([dynamic]Item, allocator)
	for b in Block {if i := item_of_block(b); i != NO_ITEM {append(&items, i)}}
	for t in Tool {append(&items, item_of_tool(t))}
	return items[:]
}

// block_drop: the item breaking b leaves (none for what players may not
// place: ores, plants, ice are data to give drops of their own later).
block_drop :: proc(b: Block) -> Item {
	return item_of_block(b)
}

// Stack: some of one item (count 0: empty, item NO_ITEM).
Stack :: struct {
	item:  Item,
	count: int,
}

stack_empty :: proc(s: Stack) -> bool {
	return s.count <= 0 || s.item == NO_ITEM
}
