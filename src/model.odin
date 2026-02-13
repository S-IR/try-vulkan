package main
import os "core:os/os2"
import "core:strings"
import c "vendor:cgltf"
Vertex :: struct {
	pos:  [3]f32,
	uv:   [2]f32,
	norm: [3]f32,
}

read_gltf_model :: proc(path: string) {
	options := c.options {
		type = .invalid,
	}

	assert(os.exists(path))
	cFilePath := strings.clone_to_cstring(path, context.temp_allocator)
	data, res := c.parse_file(options, cFilePath)
	assert(res == .success)

	defer c.free(data)
	bufferRes := c.load_buffers(options, data, cFilePath)
	assert(bufferRes == .success)

	indicesTemp := make([dynamic]u32, context.temp_allocator)
	verticesTemp := make([dynamic]Vertex, context.temp_allocator)
}
