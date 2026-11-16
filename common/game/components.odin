package game

// The components every entity kind is built from, shared by server and
// client (entities v2). Each is plain data, at most MAX_COMPONENT_SIZE bytes
// (a larger one is set at spawn only, see archetype.odin).
// Components the server alone needs (Steer holds a path) are registered by
// the server after these: its ids start at FIRST_SERVER_COMPONENT.
//
// A "tag" component has one byte so the store can carry it; only its
// presence means something.

// Component ids, the index into entity_component_infos().
C_TRANSFORM :: Component(0)
C_PHYSICS :: Component(1)
C_HEALTH :: Component(2)
C_AGE :: Component(3)
C_STACK :: Component(4)
C_OWNER :: Component(5)
C_FIELDS :: Component(6)
C_PLAYER_LINK :: Component(7)
C_NATURAL :: Component(8)
C_ORIGIN :: Component(9)
C_HURT_BY :: Component(10)
C_FROZEN :: Component(11)
C_TAGS :: Component(12)
FIRST_SERVER_COMPONENT :: Component(13)

// Transform: where an entity is. position is the bottom centre.
Transform :: struct {
	position:   [3]f64,
	yaw, pitch: f32,
}

// Physics: a body that moves (kinds with physics walker, item, projectile).
Physics :: struct {
	velocity:  [3]f32,
	on_ground: bool,
}

// Entity_Health: today's health.
Entity_Health :: struct {
	health: i32,
	max:    i32, // its most: its kind's health, unless a game set another (entity_set_max_health)
}

Age :: struct {
	ticks: i32,
}

Component_Stack :: struct {
	stack: Stack,
}

// Owner: who fired or dropped it (its seat, -1: nobody, and the seat's generation
// then: a seat is taken again by others, its generation never), and for a rocket the
// journal action that fired it (0: none). A creature's shot names the creature (its
// id; 0: none) and carries the damage it does where it lands.
Owner :: struct {
	client:     i32,
	action:     u32,
	generation: u32,
	entity:     u32,
	damage:     f32,
}

// Fields: a pack kind's declared fields, saved, not replicated.
Fields :: struct {
	data: [16]u8,
}

// Player_Link: the client a player entity stands for.
Player_Link :: struct {
	client: u16,
}

// Natural (tag): spawned by natural spawning, so it may despawn.
Natural :: struct {
	_: u8,
}

// Origin: M45's action that spawned the entity.
Origin :: struct {
	action: u32,
}

// Hurt_By: the last damage, kept 10 s (by tick).
Hurt_By :: struct {
	action: u32,
	entity: Entity_Id,
	cause:  u8,
	tick:   u32, // the server tick of the damage
}

// Frozen (tag): its chunk, or the one below, is not ready.
Frozen :: struct {
	_: u8,
}

// Tags: indices into the world's tag names (0: none).
Tags :: struct {
	tags: [4]u16,
}

@(private = "file")
component_info :: proc(name: string, $T: typeid) -> Component_Info {
	return Component_Info{name = name, type = T, size = size_of(T), align = align_of(T)}
}

// entity_component_infos: the shared components, in id order. A store is
// initialised with these followed by the server's own.
entity_component_infos :: proc() -> [13]Component_Info {
	return {
		C_TRANSFORM = component_info("transform", Transform),
		C_PHYSICS = component_info("physics", Physics),
		C_HEALTH = component_info("health", Entity_Health),
		C_AGE = component_info("age", Age),
		C_STACK = component_info("stack", Component_Stack),
		C_OWNER = component_info("owner", Owner),
		C_FIELDS = component_info("fields", Fields),
		C_PLAYER_LINK = component_info("player_link", Player_Link),
		C_NATURAL = component_info("natural", Natural),
		C_ORIGIN = component_info("origin", Origin),
		C_HURT_BY = component_info("hurt_by", Hurt_By),
		C_FROZEN = component_info("frozen", Frozen),
		C_TAGS = component_info("tags", Tags),
	}
}
