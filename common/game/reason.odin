package game

// Why an item was made or unmade (the server's ledger, server/ledger.odin;
// telemetry's Item_Created and Item_Destroyed carry the number).

// Reason: append-only (the number is in the event's n1).
Reason :: enum u8 {
	Drop_Block, // what a broken block leaves (block_drop)
	Drop_Mob, // wool from a sheep
	Give, // admin_give
	Kit, // a new player's kit
	Catalog, // taken from the creative catalog
	Spill_Old, // found with no owner on load (a saved character's overflow)
	Place, // used up placing a block
	Use, // fed to a sheep
	Clear, // admin_clear
	Expire, // an item entity's age
	Catalog_Return, // put back in the catalog (the cursor's stack replaced by a Take)
	Void, // the world refused it (no room for the entity)
	Scope_In, // came into memory: a player joined, a world loaded
	Scope_Out, // left memory: a player left, a world unloaded
}

// reason_name: in the log and in reports.
reason_name :: proc(r: Reason) -> string {
	switch r {
	case .Drop_Block:
		return "drop_block"
	case .Drop_Mob:
		return "drop_mob"
	case .Give:
		return "give"
	case .Kit:
		return "kit"
	case .Catalog:
		return "catalog"
	case .Spill_Old:
		return "spill_old"
	case .Place:
		return "place"
	case .Use:
		return "use"
	case .Clear:
		return "clear"
	case .Expire:
		return "expire"
	case .Catalog_Return:
		return "catalog_return"
	case .Void:
		return "void"
	case .Scope_In:
		return "scope_in"
	case .Scope_Out:
		return "scope_out"
	}
	return ""
}
