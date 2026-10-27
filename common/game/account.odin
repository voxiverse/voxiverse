package game

import "core:crypto"
import "core:crypto/ed25519"
import "core:encoding/hex"

// Accounts: an account is an Ed25519 key pair the client makes and keeps;
// the public key is the account. Joining, the server sends a nonce and the
// client signs it (proof_message): nobody can join as an account without
// its private key, and a proof is good for one nonce only.

Account :: distinct [ed25519.PUBLIC_KEY_SIZE]u8
Signature :: distinct [ed25519.SIGNATURE_SIZE]u8
Nonce :: distinct [32]u8

// Account_Key: an account's private half (the client's).
Account_Key :: struct {
	private: ed25519.Private_Key,
	account: Account,
}

@(private = "file")
PROOF_CONTEXT :: "voxiverse join v1"

// account_key_make: a new account.
account_key_make :: proc() -> (k: Account_Key) {
	seed: [ed25519.PRIVATE_KEY_SIZE]u8
	crypto.rand_bytes(seed[:])
	account_key_set(&k, seed[:])
	return
}

// account_key_set: the account of a private key's 32 bytes (a saved one;
// tests make theirs from a name).
account_key_set :: proc(k: ^Account_Key, seed: []u8) -> bool {
	if !ed25519.private_key_set_bytes(&k.private, seed) {return false}
	ed25519.private_key_public_bytes(&k.private, k.account[:])
	return true
}

account_key_seed :: proc(k: ^Account_Key) -> (seed: [ed25519.PRIVATE_KEY_SIZE]u8) {
	ed25519.private_key_bytes(&k.private, seed[:])
	return
}

// proof_message: what a client signs to prove its account: the context,
// the nonce, the account.
@(private = "file")
proof_message :: proc(nonce: Nonce, account: Account) -> (m: [len(PROOF_CONTEXT) + 64]u8) {
	copy(m[:], PROOF_CONTEXT)
	n, a := nonce, account
	copy(m[len(PROOF_CONTEXT):], n[:])
	copy(m[len(PROOF_CONTEXT) + 32:], a[:])
	return
}

account_sign :: proc(k: ^Account_Key, nonce: Nonce) -> (sig: Signature) {
	m := proof_message(nonce, k.account)
	ed25519.sign(&k.private, m[:], sig[:])
	return
}

account_verify :: proc(account: Account, nonce: Nonce, sig: Signature) -> bool {
	pub: ed25519.Public_Key
	a, s := account, sig
	if !ed25519.public_key_set_bytes(&pub, a[:]) {return false}
	m := proof_message(nonce, account)
	return ed25519.verify(&pub, m[:], s[:])
}

// nonce_make: a fresh challenge.
nonce_make :: proc() -> (n: Nonce) {
	crypto.rand_bytes(n[:])
	return
}

// account_text: an account as 64 hex digits (file names, logs, configs).
account_text :: proc(a: Account, allocator := context.temp_allocator) -> string {
	b := a
	return string(hex.encode(b[:], allocator))
}

account_parse :: proc(text: string) -> (a: Account, ok: bool) {
	if len(text) != 2 * len(Account) {return}
	bytes := hex.decode(transmute([]u8)text, context.temp_allocator) or_return
	copy(a[:], bytes)
	return a, true
}
