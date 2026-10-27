package netcode

import "core:encoding/endian"
import "core:net"
import "core:os"
import "core:time"

// Packet captures: a socket can write every datagram it sends and receives
// to a pcap file, as IPv4/UDP packets, for Wireshark with the dissector in
// tools/wireshark (no capture driver or root needed, loopback included).
//
//	cap: Capture
//	capture_open(&cap, "build/net.pcap")
//	socket.capture = &cap
//	... capture_close(&cap)

Capture :: struct {
	file:  ^os.File,
	start: time.Time,
}

capture_open :: proc(c: ^Capture, path: string) -> bool {
	f, err := os.create(path)
	if err != nil {return false}
	c^ = {
		file  = f,
		start = time.now(),
	}
	header: [24]u8
	endian.put_u32(header[0:], .Little, 0xa1b2c3d4) // pcap, microseconds
	endian.put_u16(header[4:], .Little, 2)
	endian.put_u16(header[6:], .Little, 4)
	endian.put_u32(header[16:], .Little, 65535) // snapshot length
	endian.put_u32(header[20:], .Little, 228) // LINKTYPE_IPV4
	os.write(f, header[:])
	return true
}

capture_close :: proc(c: ^Capture) {
	if c.file != nil {os.close(c.file)}
	c^ = {}
}

// capture_packet records one datagram from -> to.
capture_packet :: proc(c: ^Capture, from, to: net.Endpoint, data: []u8) {
	if c == nil || c.file == nil {return}
	now := time.now()
	usec := time.duration_microseconds(time.diff(time.Time{}, now))
	ip_len := 20 + 8 + len(data)
	buf: [16 + 28 + MTU + 1]u8
	b := buf[:16 + 28 + len(data)]
	endian.put_u32(b[0:], .Little, u32(i64(usec) / 1_000_000))
	endian.put_u32(b[4:], .Little, u32(i64(usec) % 1_000_000))
	endian.put_u32(b[8:], .Little, u32(ip_len))
	endian.put_u32(b[12:], .Little, u32(ip_len))
	ip := b[16:]
	ip[0] = 0x45 // IPv4, 20-byte header
	endian.put_u16(ip[2:], .Big, u16(ip_len))
	ip[8] = 64 // time to live
	ip[9] = 17 // UDP
	src, dst := address4(from), address4(to)
	copy(ip[12:16], src[:])
	copy(ip[16:20], dst[:])
	endian.put_u16(ip[10:], .Big, ip_checksum(ip[:20]))
	udp := ip[20:]
	endian.put_u16(udp[0:], .Big, u16(from.port))
	endian.put_u16(udp[2:], .Big, u16(to.port))
	endian.put_u16(udp[4:], .Big, u16(8 + len(data)))
	copy(udp[8:], data)
	os.write(c.file, b)
}

@(private = "file")
address4 :: proc(e: net.Endpoint) -> [4]u8 {
	if a, ok := e.address.(net.IP4_Address); ok {return cast([4]u8)a}
	return {}
}

@(private = "file")
ip_checksum :: proc(h: []u8) -> u16 {
	sum: u32
	for i := 0; i < len(h); i += 2 {sum += u32(h[i]) << 8 | u32(h[i + 1])}
	for sum > 0xffff {sum = sum & 0xffff + sum >> 16}
	return ~u16(sum)
}
