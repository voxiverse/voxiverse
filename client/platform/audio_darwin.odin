package platform

import CF "core:sys/darwin/CoreFoundation"
import AT "vendor:darwin/AudioToolbox"

// The sound card on macOS: the default output Audio Unit
// (kAudioUnitSubType_DefaultOutput), which follows the system's default
// output by itself and converts our format, set on its input (interleaved
// stereo f32 at the caller's rate), to the device's. Core Audio calls the
// render callback on its own real-time I/O thread, a device buffer at a
// time (the device's own size: we leave it as the system set it).
// AudioOutputUnitStop returns after the last callback.

Native_Audio :: struct {
	unit: AT.Unit,
}

@(private)
native_audio_open :: proc(a: ^Audio_Output) -> string {
	n := &a.native
	desc := AT.ComponentDescription {
		componentType         = AT.kUnitType_Output,
		componentSubType      = AT.kUnitSubType_DefaultOutput,
		componentManufacturer = AT.kUnitManufacturer_Apple,
	}
	component := AT.ComponentFindNext(nil, &desc)
	if component == nil {return audio_fail(a, "no default output Audio Unit")}
	if r := AT.ComponentInstanceNew(component, &n.unit); r != 0 {
		n.unit = nil
		return audio_fail(a, "AudioComponentInstanceNew failed (OSStatus %d)", r)
	}
	format := AT.StreamBasicDescription {
		mSampleRate       = f64(a.rate),
		mFormatID         = .LinearPCM,
		mFormatFlags      = .NativeFloatPacked, // float, packed, interleaved
		mBytesPerPacket   = AUDIO_CHANNELS * size_of(f32),
		mFramesPerPacket  = 1,
		mBytesPerFrame    = AUDIO_CHANNELS * size_of(f32),
		mChannelsPerFrame = AUDIO_CHANNELS,
		mBitsPerChannel   = 8 * size_of(f32),
	}
	callback := AT.AURenderCallbackStruct {
		inputProc       = render,
		inputProcRefCon = a,
	}
	step := "the stream format"
	r := AT.UnitSetProperty(
		n.unit,
		AT.kUnitProperty_StreamFormat,
		AT.kUnitScope_Input,
		0,
		&format,
		size_of(format),
	)
	if r == 0 {
		step = "the render callback"
		r = AT.UnitSetProperty(
			n.unit,
			AT.kUnitProperty_SetRenderCallback,
			AT.kUnitScope_Input,
			0,
			&callback,
			size_of(callback),
		)
	}
	if r == 0 {
		step = "AudioUnitInitialize"
		r = AT.UnitInitialize(n.unit)
	}
	// The device's buffer, in the device's frames (its rate may differ).
	frames: u32
	size := u32(size_of(frames))
	if r == 0 &&
	   AT.UnitGetProperty(
		   n.unit,
		   AT.kDevicePropertyBufferFrameSize,
		   AT.kUnitScope_Global,
		   0,
		   &frames,
		   &size,
	   ) ==
		   0 {
		a.period, a.buffer = frames, frames
	}
	if r == 0 {
		step = "AudioOutputUnitStart"
		r = AT.OutputUnitStart(n.unit)
	}
	if r != 0 {
		AT.UnitUninitialize(n.unit)
		AT.ComponentInstanceDispose(n.unit)
		n.unit = nil
		return audio_fail(a, "%s failed (OSStatus %d)", step, r)
	}
	return ""
}

@(private)
native_audio_close :: proc(a: ^Audio_Output) {
	n := &a.native
	if n.unit == nil {return}
	AT.OutputUnitStop(n.unit)
	AT.UnitUninitialize(n.unit)
	AT.ComponentInstanceDispose(n.unit)
	n.unit = nil
}

@(private = "file")
render :: proc "c" (
	ref: rawptr,
	flags: ^AT.UnitRenderActionFlags,
	stamp: ^AT.TimeStamp,
	bus: u32,
	frames: u32,
	data: ^AT.BufferList,
) -> CF.OSStatus {
	a := (^Audio_Output)(ref)
	buffer := &data.mBuffers[0]
	out := ([^]f32)(buffer.mData)[:buffer.mDataByteSize / size_of(f32)]
	a.fill(a.user, out[:min(len(out), AUDIO_CHANNELS * int(frames))])
	return 0
}
