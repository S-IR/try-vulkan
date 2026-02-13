package obj

import "core:os"
import "core:strconv"
import "core:strings"

Vertex :: struct {
	pos:  [3]f32,
	uv:   [2]f32,
	norm: [3]f32,
}

Mesh :: struct {
	vertices: [dynamic]Vertex,
	indices:  [dynamic]u32,
}

load_obj :: proc(path: string, allocator := context.allocator) -> (Mesh, bool) {
	data, ok := os.read_entire_file(path)
	if !ok do return {}, false
	defer delete(data)

	src := string(data)
	positions: [dynamic][3]f32
	texcoords: [dynamic][2]f32
	normals: [dynamic][3]f32
	mesh := Mesh {
		vertices = make([dynamic]Vertex, allocator),
		indices  = make([dynamic]u32, allocator),
	}

	defer {
		delete(positions)
		delete(texcoords)
		delete(normals)
	}

	for lineW in strings.split_lines_iterator(&src) {
		line := strings.trim_space(lineW)
		if line == "" || line[0] == '#' do continue

		parts := strings.split(line, " ")
		if len(parts) < 2 {
			delete(parts)
			continue
		}
		defer delete(parts)
		okParse := true
		switch parts[0] {
		case "v":
			x, y, z: f32
			x, okParse = strconv.parse_f32(parts[1])
			if !okParse do return {}, false
			y, okParse = strconv.parse_f32(parts[2])
			if !okParse do return {}, false
			z, okParse = strconv.parse_f32(parts[3])
			if !okParse do return {}, false

			append(&positions, [3]f32{x, y, z})

		case "vt":
			u, v: f32
			u, okParse = strconv.parse_f32(parts[1])
			if !okParse do return {}, false
			v, okParse = strconv.parse_f32(parts[2])
			if !okParse do return {}, false
			append(&texcoords, [2]f32{u, v})

		case "vn":
			x, y, z: f32
			x, okParse = strconv.parse_f32(parts[1])
			if !okParse do return {}, false
			y, okParse = strconv.parse_f32(parts[2])
			if !okParse do return {}, false
			z, okParse = strconv.parse_f32(parts[3])
			if !okParse do return {}, false
			append(&normals, [3]f32{x, y, z})

		case "f":
			// Expects 3 groups: v/vt/vn
			for i in 1 ..= 3 {
				indices := strings.split(parts[i], "/", context.temp_allocator)
				pIdx, tIdx, nIdx: int

				pIdx, okParse = strconv.parse_int(indices[0])
				if !okParse do return {}, false

				tIdx, okParse = strconv.parse_int(indices[1])
				if !okParse do return {}, false

				nIdx, okParse = strconv.parse_int(indices[2])
				if !okParse do return {}, false
				pIdx -= 1
				tIdx -= 1
				nIdx -= 1

				vert := Vertex {
					pos  = positions[pIdx],
					uv   = texcoords[tIdx],
					norm = normals[nIdx],
				}
				// Simple vertex deduplication (optional, but keeps it small)
				found := -1
				for v, j in mesh.vertices {
					if v.pos == vert.pos && v.uv == vert.uv && v.norm == vert.norm {
						found = j
						break
					}
				}
				if found == -1 {
					append(&mesh.indices, u32(len(mesh.vertices)))
					append(&mesh.vertices, vert)
				} else {
					append(&mesh.indices, u32(found))
				}
			}
		}
	}

	delete(mesh.vertices)
	delete(mesh.indices)
	return mesh, true
}
// delete_obj :: proc(m: Mesh) {
// 	delete(m.indices)
// 	delete(m.vertices)
// }
