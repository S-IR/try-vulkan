package main
import "../modules/vma"
import "core:container/small_array"
import "core:flags/example"

import "base:intrinsics"
import "core:fmt"
import "core:mem"
import os "core:os/os2"
import "core:path/filepath"
import "core:strings"
import c "vendor:cgltf"
import stbImage "vendor:stb/image"
import vk "vendor:vulkan"
GltfVertex :: struct {
	pos:  [3]f32,
	uv:   [2]f32,
	norm: [3]f32,
}
GltfPrimitiveImage :: struct {
	data:                    [^]u8,
	width, height, channels: i32,
	magFilter:               c.filter_type,
	minFilter:               c.filter_type,
	wrapS:                   c.wrap_mode,
	wrapT:                   c.wrap_mode,
}

GltfPrimitive :: struct {
	vertices:        [dynamic]GltfVertex,
	indices:         [dynamic]u32,
	image:           GltfPrimitiveImage,
	type:            c.primitive_type,
	baseColorFactor: [4]f32,
}

@(require_results)
read_gltf_model :: proc(
	path: string,
	cb: vk.CommandBuffer,
	allocator := context.allocator,
) -> (
	model: Model,
) // primitives: [dynamic]^Primitive,
{
	assert(os.exists(path))
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

	when ODIN_DEBUG {
		validationRes := c.validate(data)
		assert(validationRes == .success)
	}

	assert(len(data.scenes) > 0)
	defaultScene := data.scenes[0]
	for node in defaultScene.nodes {
		if node.mesh == nil do continue

		mesh := node.mesh
		for primitive in mesh.primitives {

			primInfo := GltfPrimitive {
				vertices = make([dynamic]GltfVertex, allocator),
				indices  = make([dynamic]u32, allocator),
				type     = primitive.type,
			}

			positions := make([dynamic][3]f32, context.temp_allocator)
			normals := make([dynamic][3]f32, context.temp_allocator)
			uvs := make([dynamic][2]f32, context.temp_allocator)


			for attrib in primitive.attributes {
				accessor := attrib.data
				#partial switch attrib.type {
				case .position:
					num_components := c.num_components(accessor.type)
					numFloats := accessor.count * num_components
					resize(&positions, accessor.count)
					floats_read := c.accessor_unpack_floats(
						accessor,
						transmute([^]f32)raw_data(positions),
						numFloats,
					)
					assert(floats_read == numFloats)
				case .normal:
					numComponents := c.num_components(accessor.type)
					numNormals := accessor.count * numComponents
					resize(&normals, accessor.count)
					normalsRead := c.accessor_unpack_floats(
						attrib.data,
						transmute([^]f32)raw_data(normals),
						numNormals,
					)
					assert(normalsRead == numNormals)
				case .texcoord:
					numComponents := c.num_components(accessor.type)
					numFloats := accessor.count * numComponents
					resize(&uvs, accessor.count)

					floatsRead := c.accessor_unpack_floats(
						accessor,
						transmute([^]f32)raw_data(uvs),
						numFloats,
					)
					assert(floatsRead == numFloats)
				}

			}
			assert(len(positions) == len(normals) && len(normals) == len(uvs))
			resize(&primInfo.vertices, len(positions))
			for &vert, i in primInfo.vertices {
				vert = {
					pos  = positions[i],
					norm = normals[i],
					uv   = uvs[i],
				}
			}


			if primitive.indices != nil {
				resize(&primInfo.indices, primitive.indices.count)

				intsRead := c.accessor_unpack_indices(
					primitive.indices,
					raw_data(primInfo.indices),
					size_of(u32),
					uint(len(primInfo.indices)),
				)
				assert(intsRead == primitive.indices.count)
			}

			material := primitive.material

			if !material.has_pbr_metallic_roughness do continue

			metallicRoughness := material.pbr_metallic_roughness
			primInfo.baseColorFactor = metallicRoughness.base_color_factor


			texView := metallicRoughness.base_color_texture
			if texView.texture == nil do texView = metallicRoughness.metallic_roughness_texture

			if texView.texture == nil {
				fmt.println("Warning: No texture found for primitive, skipping")
				continue
			}
			// assert(texView.texture != nil)

			texture := texView.texture
			image := texture.image_

			DESIRED_CHANNELS :: 4

			if image.uri != nil {
				modelDir := filepath.dir(path, context.temp_allocator)
				uriNormalString := strings.clone_from_cstring(image.uri, context.temp_allocator)
				finalPath := filepath.join({modelDir, uriNormalString}, context.temp_allocator)
				finalPathCstring := strings.clone_to_cstring(finalPath, context.temp_allocator)
				assert(os.exists(finalPath))

				primInfo.image.data = stbImage.load(
					finalPathCstring,
					&primInfo.image.width,
					&primInfo.image.height,
					nil,
					DESIRED_CHANNELS,
				)


			} else if image.buffer_view != nil {
				view := image.buffer_view
				buffer := view.buffer

				dataPtr := ([^]u8)(buffer.data)
				offset := view.offset
				size := view.size
				startOfImage := mem.ptr_offset(dataPtr, offset)
				primInfo.image.data = stbImage.load_from_memory(
					startOfImage,
					i32(size),
					&primInfo.image.width,
					&primInfo.image.height,
					nil,
					DESIRED_CHANNELS,
				)
			}

			assert(primInfo.image.data != nil)
			assert(primInfo.image.width != 0)
			assert(primInfo.image.height != 0)
			primInfo.image.channels = DESIRED_CHANNELS

			if texture.sampler != nil {
				sampler := texture.sampler
				primInfo.image.magFilter = sampler.mag_filter
				primInfo.image.minFilter = sampler.min_filter
				primInfo.image.wrapS = sampler.wrap_s
				primInfo.image.wrapT = sampler.wrap_t
			}
			primitive_assert(primInfo)

			renderObj := RenderObject{}
			assert(len(primInfo.vertices) != 0)
			vertexBufferSize := size_of(primInfo.vertices[0]) * len(primInfo.vertices)

			vk_chk(
				vma.create_buffer(
					vkAllocator,
					{
						sType = .BUFFER_CREATE_INFO,
						size = vk.DeviceSize(vertexBufferSize),
						usage = {.VERTEX_BUFFER},
					},
					{
						flags = {
							.Host_Access_Sequential_Write,
							.Host_Access_Allow_Transfer_Instead,
						},
						usage = .Auto,
					},
					&renderObj.primitive.vertexBuffer,
					&renderObj.primitive.vertexAlloc,
					nil,
				),
			)

			vertexPtr: rawptr
			vma.map_memory(vkAllocator, renderObj.primitive.vertexAlloc, &vertexPtr)
			mem.copy(vertexPtr, raw_data(primInfo.vertices), vertexBufferSize)

			vertexCount := len(primInfo.vertices)
			assert(vertexCount < int(max(u32)))
			renderObj.primitive.verticesCount = u32(vertexCount)


			indexBufferSize := size_of(primInfo.indices[0]) * len(primInfo.indices)
			vk_chk(
				vma.create_buffer(
					vkAllocator,
					{
						sType = .BUFFER_CREATE_INFO,
						size = vk.DeviceSize(indexBufferSize),
						usage = {.INDEX_BUFFER},
					},
					{
						flags = {
							.Host_Access_Sequential_Write,
							.Host_Access_Allow_Transfer_Instead,
						},
						usage = .Auto,
					},
					&renderObj.primitive.indexBuffer,
					&renderObj.primitive.indexAlloc,
					nil,
				),
			)
			indexPtr: ^u8
			vma.map_memory(vkAllocator, renderObj.primitive.indexAlloc, (^rawptr)(&indexPtr))

			mem.copy(
				indexPtr,
				raw_data(primInfo.indices),
				size_of(primInfo.indices[0]) * len(primInfo.indices),
			)


			indexCount := len(primInfo.indices)
			assert(indexCount < int(max(u32)))
			renderObj.primitive.indexCount = u32(indexCount)
			renderObj.material.baseColorTexture = load_gltf_image(primInfo.image, cb)

			renderObj.material.baseColorFactor = metallicRoughness.base_color_factor
			#partial switch primInfo.type {
			case .triangles:
				renderObj.primitive.topology = .TRIANGLE_LIST
			case:
				unreachable()
			}

			append(&model.renderObjs, renderObj)


		}
	}

	return model
}
model_destroy :: proc(m: Model) {
	for obj in m.renderObjs {
		if obj.primitive.vertexBuffer != {} do vma.destroy_buffer(vkAllocator, obj.primitive.vertexBuffer, obj.primitive.vertexAlloc)
		if obj.primitive.indexBuffer != {} do vma.destroy_buffer(vkAllocator, obj.primitive.indexBuffer, obj.primitive.indexAlloc)
		view := obj.material.baseColorTexture.descriptor.imageView
		if view != {} do vk.DestroyImageView(vkDevice, view, nil)

		sampler := obj.material.baseColorTexture.descriptor.sampler
		if sampler != {} do vk.DestroySampler(vkDevice, sampler, nil)


		image := obj.material.baseColorTexture.image
		if image != {} do vma.destroy_image(vkAllocator, image, obj.material.baseColorTexture.allocation)

	}

}
primitive_assert :: proc(p: GltfPrimitive) {
	when ODIN_DEBUG {
		assert(p.indices != nil)
		assert(len(p.indices) != 0)

		assert(p.vertices != nil); assert(len(p.vertices) != 0)
		for vert in p.vertices {
			assert(vert != {})
		}
		assert(p.baseColorFactor != {})

	}
	primitive_image_assert(p.image)
}
primitive_image_assert :: proc(pi: GltfPrimitiveImage) {
	when ODIN_DEBUG {
		assert(pi.data != nil)
		assert(pi.width != 0)
		assert(pi.height != 0)
		assert(pi.channels != 0)
	}
}
Model :: struct {
	renderObjs: [dynamic]RenderObject,
}
RenderObject :: struct {
	primitive: GPUPrimitive,
	material:  GPUMaterial,
}
GPUMaterial :: struct {
	baseColorTexture: GPUTexture,
	baseColorFactor:  [4]f32,
}
GPU_MESH_MAX_DESCRIPTORS :: 5
GPUPrimitive :: struct {
	vertexBuffer:  vk.Buffer,
	vertexAlloc:   vma.Allocation,
	verticesCount: u32,
	indexBuffer:   vk.Buffer,
	indexAlloc:    vma.Allocation,
	indexCount:    u32,
	topology:      vk.PrimitiveTopology,
	transform:     matrix[4, 4]f32,
}
