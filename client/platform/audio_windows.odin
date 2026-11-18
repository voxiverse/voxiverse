package platform

import "core:dynlib"
import "core:sync"
import win "core:sys/windows"

// The sound card on Windows: WASAPI, shared mode, event-driven. The output's
// thread joins COM (multithreaded) and MMCSS's "Pro Audio" class, opens the
// default render endpoint (console role) and initializes it with the
// caller's format, interleaved stereo f32 at the caller's rate, and
// AUTOCONVERTPCM | SRC_DEFAULT_QUALITY, so Windows converts to its mix
// format; the buffer asked for is AUDIO_BUFFER_MS. The audio engine signals
// the event once a device period; the thread asks for the padding and fills
// the rest of the buffer. When the endpoint is lost (AUDCLNT_E_DEVICE_
// INVALIDATED, or any other failure of the stream) or the default output
// changes (IMMNotificationClient), the stream is closed and the default
// opened again, every AUDIO_RETRY_MS until one opens; the game hears a gap.
// Every COM object lives on this thread, from open to release.

Native_Audio :: struct {
	enumerator:      ^IMMDeviceEnumerator,
	client:          ^IAudioClient, // nil while lost
	render:          ^IAudioRenderClient,
	event:           win.HANDLE, // auto-reset; the audio engine's and native_audio_wake's
	frames:          u32, // the stream's buffer
	notify:          Notification_Client,
	registered:      bool, // notify is registered with the enumerator
	default_changed: bool, // (atomic) set by notify
	running:         bool, // the stream has started (an empty buffer is an underrun)
	com:             bool, // CoInitializeEx succeeded: CoUninitialize at the end
	avrt:            dynlib.Library,
	mmcss:           win.HANDLE,
}

@(private = "file")
AUDIO_RETRY_MS :: 500

@(private)
native_audio_start :: proc(a: ^Audio_Output) -> string {
	n := &a.native
	hr := win.CoInitializeEx(nil, .MULTITHREADED)
	if win.FAILED(hr) {return audio_fail(a, "CoInitializeEx failed (hr=0x%08X)", u32(hr))}
	n.com = true
	mmcss_join(n)
	n.event = win.CreateEventW(nil, false, false, nil)
	if n.event == nil {return audio_fail(a, "CreateEventW failed (%d)", win.GetLastError())}
	hr = win.CoCreateInstance(
		&CLSID_MMDeviceEnumerator,
		nil,
		win.CLSCTX_ALL,
		&IID_IMMDeviceEnumerator,
		(^rawptr)(&n.enumerator),
	)
	if win.FAILED(hr) {
		n.enumerator = nil
		return audio_fail(a, "CoCreateInstance MMDeviceEnumerator failed (hr=0x%08X)", u32(hr))
	}
	n.notify = {
		vtable = &notification_vtable,
		audio  = a,
	}
	n.registered = win.SUCCEEDED(n.enumerator->RegisterEndpointNotificationCallback(&n.notify))
	return stream_open(a)
}

@(private)
native_audio_run :: proc(a: ^Audio_Output) {
	n := &a.native
	for !sync.atomic_load(&a.stopping) {
		// (a stream that stops signalling is waited for at most a second)
		win.WaitForSingleObject(n.event, 1000 if n.client != nil else AUDIO_RETRY_MS)
		if sync.atomic_load(&a.stopping) {break}
		moved := sync.atomic_exchange(&n.default_changed, false)
		if n.client != nil && !moved && win.SUCCEEDED(stream_feed(a)) {continue}
		stream_close(a)
		if stream_open(a) == "" {sync.atomic_add(&a.reopens, 1)}
	}
}

@(private)
native_audio_stop :: proc(a: ^Audio_Output) {
	n := &a.native
	stream_close(a)
	if n.registered {n.enumerator->UnregisterEndpointNotificationCallback(&n.notify)}
	if n.enumerator != nil {n.enumerator->Release()}
	n.registered, n.enumerator = false, nil
	if n.mmcss != nil {
		if revert, found := dynlib.symbol_address(n.avrt, "AvRevertMmThreadCharacteristics");
		   found {
			(cast(proc "system" (task: win.HANDLE) -> win.BOOL)revert)(n.mmcss)
		}
	}
	if n.avrt != nil {dynlib.unload_library(n.avrt)}
	n.mmcss, n.avrt = nil, nil
	if n.com {win.CoUninitialize()}
	n.com = false
}

@(private)
native_audio_wake :: proc(a: ^Audio_Output) {
	win.SetEvent(a.native.event)
}

// native_audio_free: after the thread has ended, the event the caller woke
// it with.
@(private)
native_audio_free :: proc(a: ^Audio_Output) {
	if a.native.event != nil {win.CloseHandle(a.native.event)}
	a.native.event = nil
}

// mmcss_join puts the thread in MMCSS's "Pro Audio" class (avrt.dll, loaded
// at run time as XInput is; without it the thread keeps its high priority).
@(private = "file")
mmcss_join :: proc(n: ^Native_Audio) {
	lib, ok := dynlib.load_library("avrt.dll")
	if !ok {return}
	n.avrt = lib
	join, found := dynlib.symbol_address(lib, "AvSetMmThreadCharacteristicsW")
	if !found {return}
	index: win.DWORD
	n.mmcss = (cast(proc "system" (task: win.LPCWSTR, index: ^win.DWORD) -> win.HANDLE)join)(
		win.L("Pro Audio"),
		&index,
	)
}

// stream_open opens the default endpoint's stream, fills its buffer and
// starts it.
@(private = "file")
stream_open :: proc(a: ^Audio_Output) -> string {
	n := &a.native
	device: ^IMMDevice
	hr := n.enumerator->GetDefaultAudioEndpoint(.eRender, .eConsole, &device)
	if win.FAILED(hr) {return audio_fail(a, "no default output (hr=0x%08X)", u32(hr))}
	hr = device->Activate(&IID_IAudioClient, win.CLSCTX_ALL, nil, (^rawptr)(&n.client))
	device->Release()
	if win.FAILED(hr) {
		n.client = nil
		return audio_fail(a, "IMMDevice::Activate failed (hr=0x%08X)", u32(hr))
	}
	format := win.WAVEFORMATEXTENSIBLE {
		Format = {
			wFormatTag = win.WAVE_FORMAT_EXTENSIBLE,
			nChannels = AUDIO_CHANNELS,
			nSamplesPerSec = a.rate,
			nAvgBytesPerSec = a.rate * AUDIO_CHANNELS * size_of(f32),
			nBlockAlign = AUDIO_CHANNELS * size_of(f32),
			wBitsPerSample = 8 * size_of(f32),
			cbSize = size_of(win.WAVEFORMATEXTENSIBLE) - size_of(win.WAVEFORMATEX),
		},
		dwChannelMask = {.FRONT_LEFT, .FRONT_RIGHT},
		SubFormat = KSDATAFORMAT_SUBTYPE_IEEE_FLOAT,
	}
	format.Samples.wValidBitsPerSample = 8 * size_of(f32)
	flags: win.DWORD =
		AUDCLNT_STREAMFLAGS_EVENTCALLBACK |
		AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM |
		AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY
	buffer_100ns := win.LONGLONG(AUDIO_BUFFER_MS) * 10_000
	step := "IAudioClient::Initialize"
	hr = n.client->Initialize(.SHARED, flags, buffer_100ns, 0, &format.Format, nil)
	if win.SUCCEEDED(hr) {
		step = "IAudioClient::SetEventHandle"
		hr = n.client->SetEventHandle(n.event)
	}
	if win.SUCCEEDED(hr) {
		step = "IAudioClient::GetBufferSize"
		hr = n.client->GetBufferSize(&n.frames)
	}
	if win.SUCCEEDED(hr) {
		step = "IAudioClient::GetService"
		hr = n.client->GetService(&IID_IAudioRenderClient, (^rawptr)(&n.render))
		if win.FAILED(hr) {n.render = nil}
	}
	if win.SUCCEEDED(hr) {
		step = "the first fill"
		hr = stream_feed(a)
	}
	if win.SUCCEEDED(hr) {
		step = "IAudioClient::Start"
		hr = n.client->Start()
		n.running = win.SUCCEEDED(hr)
	}
	if win.FAILED(hr) {
		stream_close(a)
		return audio_fail(a, "%s failed (hr=0x%08X)", step, u32(hr))
	}
	period, least: win.LONGLONG
	if win.FAILED(n.client->GetDevicePeriod(&period, &least)) {period = 0}
	sync.atomic_store(&a.period, u32(i64(period) * i64(a.rate) / 10_000_000))
	sync.atomic_store(&a.buffer, n.frames)
	return ""
}

@(private = "file")
stream_close :: proc(a: ^Audio_Output) {
	n := &a.native
	if n.client != nil {n.client->Stop()}
	if n.render != nil {n.render->Release()}
	if n.client != nil {n.client->Release()}
	n.render, n.client, n.frames, n.running = nil, nil, 0, false
}

// stream_feed fills what the buffer has room for. An empty buffer, once the
// stream runs, is an underrun (the engine has played silence).
@(private = "file")
stream_feed :: proc(a: ^Audio_Output) -> win.HRESULT {
	n := &a.native
	padding: u32
	if hr := n.client->GetCurrentPadding(&padding); win.FAILED(hr) {return hr}
	frames := n.frames - padding
	if frames == 0 {return win.S_OK}
	if padding == 0 && n.running {sync.atomic_add(&a.xruns, 1)}
	data: ^u8
	if hr := n.render->GetBuffer(frames, &data); win.FAILED(hr) {return hr}
	a.fill(a.user, ([^]f32)(data)[:AUDIO_CHANNELS * frames])
	return n.render->ReleaseBuffer(frames, 0)
}

// The COM declarations, from the SDK's mmdeviceapi.h and audioclient.h (the
// vtables in header order, after IUnknown's three).

@(private = "file")
CLSID_MMDeviceEnumerator := win.GUID {
	0xBCDE0395,
	0xE52F,
	0x467C,
	{0x8E, 0x3D, 0xC4, 0x57, 0x92, 0x91, 0x69, 0x2E},
}
@(private = "file")
IID_IMMDeviceEnumerator := win.GUID {
	0xA95664D2,
	0x9614,
	0x4F35,
	{0xA7, 0x46, 0xDE, 0x8D, 0xB6, 0x36, 0x17, 0xE6},
}
@(private = "file")
IID_IMMNotificationClient := win.GUID {
	0x7991EEC9,
	0x7E89,
	0x4D85,
	{0x83, 0x90, 0x6C, 0x70, 0x3C, 0xEC, 0x60, 0xC0},
}
@(private = "file")
IID_IAudioClient := win.GUID {
	0x1CB9AD4C,
	0xDBFA,
	0x4C32,
	{0xB1, 0x78, 0xC2, 0xF5, 0x68, 0xA7, 0x03, 0xB2},
}
@(private = "file")
IID_IAudioRenderClient := win.GUID {
	0xF294ACFC,
	0x3146,
	0x4483,
	{0xA7, 0xBF, 0xAD, 0xDC, 0xA7, 0xC2, 0x60, 0xE2},
}
@(private = "file")
KSDATAFORMAT_SUBTYPE_IEEE_FLOAT := win.GUID {
	0x00000003,
	0x0000,
	0x0010,
	{0x80, 0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71},
}

@(private = "file")
AUDCLNT_STREAMFLAGS_EVENTCALLBACK :: 0x0004_0000
@(private = "file")
AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY :: 0x0800_0000
@(private = "file")
AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM :: 0x8000_0000

@(private = "file")
EDataFlow :: enum i32 {
	eRender  = 0,
	eCapture = 1,
	eAll     = 2,
}

@(private = "file")
ERole :: enum i32 {
	eConsole        = 0,
	eMultimedia     = 1,
	eCommunications = 2,
}

@(private = "file")
AUDCLNT_SHAREMODE :: enum i32 {
	SHARED    = 0,
	EXCLUSIVE = 1,
}

@(private = "file")
IMMDeviceEnumerator :: struct #raw_union {
	#subtype iunknown: win.IUnknown,
	using vtable:      ^IMMDeviceEnumerator_VTable,
}
@(private = "file")
IMMDeviceEnumerator_VTable :: struct {
	using iunknown_vtable:                  win.IUnknown_VTable,
	EnumAudioEndpoints:                     proc "system" (
		this: ^IMMDeviceEnumerator,
		flow: EDataFlow,
		state_mask: win.DWORD,
		devices: ^rawptr,
	) -> win.HRESULT,
	GetDefaultAudioEndpoint:                proc "system" (
		this: ^IMMDeviceEnumerator,
		flow: EDataFlow,
		role: ERole,
		endpoint: ^^IMMDevice,
	) -> win.HRESULT,
	GetDevice:                              proc "system" (
		this: ^IMMDeviceEnumerator,
		id: win.LPCWSTR,
		device: ^^IMMDevice,
	) -> win.HRESULT,
	RegisterEndpointNotificationCallback:   proc "system" (
		this: ^IMMDeviceEnumerator,
		client: ^Notification_Client,
	) -> win.HRESULT,
	UnregisterEndpointNotificationCallback: proc "system" (
		this: ^IMMDeviceEnumerator,
		client: ^Notification_Client,
	) -> win.HRESULT,
}

@(private = "file")
IMMDevice :: struct #raw_union {
	#subtype iunknown: win.IUnknown,
	using vtable:      ^IMMDevice_VTable,
}
@(private = "file")
IMMDevice_VTable :: struct {
	using iunknown_vtable: win.IUnknown_VTable,
	Activate:              proc "system" (
		this: ^IMMDevice,
		iid: win.REFIID,
		cls_ctx: win.DWORD,
		activation_params: ^win.PROPVARIANT,
		object: ^rawptr,
	) -> win.HRESULT,
	OpenPropertyStore:     proc "system" (
		this: ^IMMDevice,
		access: win.DWORD,
		store: ^rawptr,
	) -> win.HRESULT,
	GetId:                 proc "system" (this: ^IMMDevice, id: ^win.LPWSTR) -> win.HRESULT,
	GetState:              proc "system" (this: ^IMMDevice, state: ^win.DWORD) -> win.HRESULT,
}

@(private = "file")
IAudioClient :: struct #raw_union {
	#subtype iunknown: win.IUnknown,
	using vtable:      ^IAudioClient_VTable,
}
@(private = "file")
IAudioClient_VTable :: struct {
	using iunknown_vtable: win.IUnknown_VTable,
	Initialize:            proc "system" (
		this: ^IAudioClient,
		share_mode: AUDCLNT_SHAREMODE,
		stream_flags: win.DWORD,
		buffer_duration: win.LONGLONG, // REFERENCE_TIME, 100 ns units
		periodicity: win.LONGLONG,
		format: ^win.WAVEFORMATEX,
		session: ^win.GUID,
	) -> win.HRESULT,
	GetBufferSize:         proc "system" (this: ^IAudioClient, frames: ^u32) -> win.HRESULT,
	GetStreamLatency:      proc "system" (
		this: ^IAudioClient,
		latency: ^win.LONGLONG,
	) -> win.HRESULT,
	GetCurrentPadding:     proc "system" (this: ^IAudioClient, frames: ^u32) -> win.HRESULT,
	IsFormatSupported:     proc "system" (
		this: ^IAudioClient,
		share_mode: AUDCLNT_SHAREMODE,
		format: ^win.WAVEFORMATEX,
		closest: ^^win.WAVEFORMATEX,
	) -> win.HRESULT,
	GetMixFormat:          proc "system" (
		this: ^IAudioClient,
		format: ^^win.WAVEFORMATEX,
	) -> win.HRESULT,
	GetDevicePeriod:       proc "system" (
		this: ^IAudioClient,
		default_period, least_period: ^win.LONGLONG,
	) -> win.HRESULT,
	Start:                 proc "system" (this: ^IAudioClient) -> win.HRESULT,
	Stop:                  proc "system" (this: ^IAudioClient) -> win.HRESULT,
	Reset:                 proc "system" (this: ^IAudioClient) -> win.HRESULT,
	SetEventHandle:        proc "system" (this: ^IAudioClient, event: win.HANDLE) -> win.HRESULT,
	GetService:            proc "system" (
		this: ^IAudioClient,
		iid: win.REFIID,
		object: ^rawptr,
	) -> win.HRESULT,
}

@(private = "file")
IAudioRenderClient :: struct #raw_union {
	#subtype iunknown: win.IUnknown,
	using vtable:      ^IAudioRenderClient_VTable,
}
@(private = "file")
IAudioRenderClient_VTable :: struct {
	using iunknown_vtable: win.IUnknown_VTable,
	GetBuffer:             proc "system" (
		this: ^IAudioRenderClient,
		frames: u32,
		data: ^^u8,
	) -> win.HRESULT,
	ReleaseBuffer:         proc "system" (
		this: ^IAudioRenderClient,
		frames: u32,
		flags: win.DWORD,
	) -> win.HRESULT,
}

// Notification_Client is our IMMNotificationClient: Windows calls it on a
// thread of its own. It lives in Native_Audio (its reference count is not
// kept: it outlasts its registration) and only flags a change of the
// default output and wakes the output's thread.
@(private)
Notification_Client :: struct {
	vtable: ^Notification_Client_VTable,
	audio:  ^Audio_Output,
}
@(private = "file")
Notification_Client_VTable :: struct {
	QueryInterface:         proc "system" (
		this: ^Notification_Client,
		iid: win.REFIID,
		object: ^rawptr,
	) -> win.HRESULT,
	AddRef:                 proc "system" (this: ^Notification_Client) -> win.ULONG,
	Release:                proc "system" (this: ^Notification_Client) -> win.ULONG,
	OnDeviceStateChanged:   proc "system" (
		this: ^Notification_Client,
		id: win.LPCWSTR,
		state: win.DWORD,
	) -> win.HRESULT,
	OnDeviceAdded:          proc "system" (
		this: ^Notification_Client,
		id: win.LPCWSTR,
	) -> win.HRESULT,
	OnDeviceRemoved:        proc "system" (
		this: ^Notification_Client,
		id: win.LPCWSTR,
	) -> win.HRESULT,
	OnDefaultDeviceChanged: proc "system" (
		this: ^Notification_Client,
		flow: EDataFlow,
		role: ERole,
		id: win.LPCWSTR,
	) -> win.HRESULT,
	OnPropertyValueChanged: proc "system" (
		this: ^Notification_Client,
		id: win.LPCWSTR,
		key: win.PROPERTYKEY,
	) -> win.HRESULT,
}

@(private = "file")
notification_vtable := Notification_Client_VTable {
	QueryInterface = proc "system" (
		this: ^Notification_Client,
		iid: win.REFIID,
		object: ^rawptr,
	) -> win.HRESULT {
		if iid^ == win.IUnknown_UUID^ || iid^ == IID_IMMNotificationClient {
			object^ = this
			return win.S_OK
		}
		object^ = nil
		return transmute(win.HRESULT)u32(win.E_NOINTERFACE)
	},
	AddRef = proc "system" (this: ^Notification_Client) -> win.ULONG {return 1},
	Release = proc "system" (this: ^Notification_Client) -> win.ULONG {return 1},
	OnDeviceStateChanged = proc "system" (
		this: ^Notification_Client,
		id: win.LPCWSTR,
		state: win.DWORD,
	) -> win.HRESULT {return win.S_OK},
	OnDeviceAdded = proc "system" (this: ^Notification_Client, id: win.LPCWSTR) -> win.HRESULT {
		return win.S_OK
	},
	OnDeviceRemoved = proc "system" (this: ^Notification_Client, id: win.LPCWSTR) -> win.HRESULT {
		return win.S_OK
	},
	OnDefaultDeviceChanged = proc "system" (
		this: ^Notification_Client,
		flow: EDataFlow,
		role: ERole,
		id: win.LPCWSTR,
	) -> win.HRESULT {
		if flow == .eRender && role == .eConsole {
			sync.atomic_store(&this.audio.native.default_changed, true)
			win.SetEvent(this.audio.native.event)
		}
		return win.S_OK
	},
	OnPropertyValueChanged = proc "system" (
		this: ^Notification_Client,
		id: win.LPCWSTR,
		key: win.PROPERTYKEY,
	) -> win.HRESULT {return win.S_OK},
}
