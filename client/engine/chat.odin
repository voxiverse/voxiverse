package engine

import "core:strings"
import "core:time"

CHAT_KEEP :: 100 // lines kept

Chat_Entry :: struct {
	id:   u32, // the server's (0: a notice)
	text: string, // formatted (heap)
	at:   time.Tick,
}

// chat_add keeps a line (the oldest goes past CHAT_KEEP).
chat_add :: proc(s: ^Session, id: u32, text: string) {
	if len(s.chat) == CHAT_KEEP {
		delete(s.chat[0].text)
		ordered_remove(&s.chat, 0)
	}
	append(&s.chat, Chat_Entry{id, strings.clone(text), time.tick_now()})
}

// chat_delete: a moderator took line id back.
chat_delete :: proc(s: ^Session, id: u32) {
	for e, i in s.chat {
		if e.id == id {
			delete(e.text)
			ordered_remove(&s.chat, i)
			return
		}
	}
}
