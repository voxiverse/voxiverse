package gpu

import "core:encoding/endian"
import "core:hash/xxhash"
import "core:log"
import "core:os"
import "core:strings"
import vk "vendor:vulkan"

// The pipeline cache. Building a pipeline compiles its shaders for this GPU, which
// takes milliseconds per pipeline; a VkPipelineCache keeps the results, and its data
// is kept on disk between runs (pipeline_cache_open, saved by destroy).
//
// The file holds an XXH3-64 of the data (8 bytes, little endian), then the driver's
// data. The data begins with Vulkan's header: the vendor, the device and the driver's
// cache UUID. Data written for another GPU or driver, or whose hash does not match
// (a torn or damaged file), is not given to the driver: the cache starts empty.

// pipeline_cache_open creates the cache, from path's data when it is valid here.
// Call it before the first pipeline is created; destroy saves the cache to path.
pipeline_cache_open :: proc(g: ^Gpu, path: string) {
	data, err := os.read_entire_file_from_path(path, context.temp_allocator)
	initial: []u8
	why := "no file"
	if err == nil {
		initial, why = cache_data_usable(g, data)
	}
	info := vk.PipelineCacheCreateInfo {
		sType           = .PIPELINE_CACHE_CREATE_INFO,
		initialDataSize = len(initial),
		pInitialData    = raw_data(initial),
	}
	if result := vk.CreatePipelineCache(g.device, &info, nil, &g.pipeline_cache);
	   result != .SUCCESS {
		log.warnf("gpu pipeline cache could not be created: %v (pipelines build uncached)", result)
		g.pipeline_cache = 0
		return
	}
	set_name(g, .PIPELINE_CACHE, u64(g.pipeline_cache), "pipeline cache")
	g.pipeline_cache_path = strings.clone(path)
	if len(initial) > 0 {
		log.infof("gpu pipeline cache loaded bytes=%d path=%s", len(initial), path)
	} else {
		log.infof("gpu pipeline cache empty (%s) path=%s", why, path)
	}
}

// pipeline_cache_close saves the cache's data to its file (written beside it, then
// renamed over it: never half written) and destroys it.
@(private)
pipeline_cache_close :: proc(g: ^Gpu) {
	if g.pipeline_cache == 0 {return}
	defer {
		vk.DestroyPipelineCache(g.device, g.pipeline_cache, nil)
		g.pipeline_cache = 0
		delete(g.pipeline_cache_path)
		g.pipeline_cache_path = ""
	}
	size: int
	if vk.GetPipelineCacheData(g.device, g.pipeline_cache, &size, nil) != .SUCCESS || size == 0 {
		return
	}
	file := make([]u8, 8 + size, context.temp_allocator)
	if vk.GetPipelineCacheData(g.device, g.pipeline_cache, &size, raw_data(file[8:])) != .SUCCESS {
		return
	}
	file = file[:8 + size]
	endian.put_u64(file[:8], .Little, xxhash.XXH3_64(file[8:]))
	tmp := strings.concatenate({g.pipeline_cache_path, ".tmp"}, context.temp_allocator)
	if os.write_entire_file(tmp, file) != nil || os.rename(tmp, g.pipeline_cache_path) != nil {
		log.warnf("gpu pipeline cache not saved path=%s", g.pipeline_cache_path)
		os.remove(tmp)
		return
	}
	log.infof("gpu pipeline cache saved bytes=%d path=%s", size, g.pipeline_cache_path)
}

// cache_data_usable: the driver's data in file, if its hash matches and Vulkan's
// header says this GPU and driver wrote it; else nil and why not.
@(private = "file")
cache_data_usable :: proc(g: ^Gpu, file: []u8) -> (data: []u8, why: string) {
	HEADER :: 32 // headerSize, headerVersion, vendorID, deviceID: u32 each; UUID: 16 bytes
	if len(file) < 8 + HEADER {return nil, "too short"}
	hash, _ := endian.get_u64(file[:8], .Little)
	data = file[8:]
	if xxhash.XXH3_64(data) != hash {return nil, "damaged: its hash does not match"}
	header_size, _ := endian.get_u32(data[0:4], .Little)
	version, _ := endian.get_u32(data[4:8], .Little)
	vendor, _ := endian.get_u32(data[8:12], .Little)
	device, _ := endian.get_u32(data[12:16], .Little)
	props: vk.PhysicalDeviceProperties
	vk.GetPhysicalDeviceProperties(g.physical, &props)
	switch {
	case header_size < HEADER || version != u32(vk.PipelineCacheHeaderVersion.ONE):
		return nil, "an unknown header"
	case vendor != props.vendorID || device != props.deviceID:
		return nil, "written for another GPU"
	case props.pipelineCacheUUID != ([^][16]u8)(raw_data(data[16:32]))[0]:
		return nil, "written by another driver version"
	}
	return data, ""
}
