package base

import "core:testing"

@(private = "file")
captured_text: [256]u8
@(private = "file")
captured_len: int
@(private = "file")
captured_stream: Output_Stream

@(private = "file")
fake_write :: proc "contextless" (stream: Output_Stream, text: string) {
	captured_stream = stream
	n := min(len(captured_text) - captured_len, len(text))
	copy(captured_text[captured_len:], text[:n])
	captured_len += n
}

@(private = "file")
fake_color :: proc "contextless" (stream: Output_Stream) -> bool {
	return stream == .Err
}

@(test)
test_output_goes_through_the_installed_service :: proc(t: ^testing.T) {
	captured_len = 0
	output_install({write = fake_write, is_color = fake_color})
	defer output_install({})
	out_printfln(.Err, "disk: %s failed", "write")
	testing.expect_value(t, string(captured_text[:captured_len]), "disk: write failed\n")
	testing.expect_value(t, captured_stream, Output_Stream.Err)
	testing.expect(t, out_is_color(.Err))
	testing.expect(t, !out_is_color(.Out))
}

@(test)
test_output_without_a_service_is_dropped :: proc(t: ^testing.T) {
	output_install({})
	out_write(.Out, "nobody listens")
	out_printfln(.Err, "nor here %d", 1)
	testing.expect(t, !out_is_color(.Err))
}
