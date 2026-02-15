package main
import "../modules/vma"
import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:log"
import "core:mem"
import os "core:os/os2"
import "core:path/filepath"
import "core:strings"
import sdl "vendor:sdl3"
import stbImage "vendor:stb/image"
import vk "vendor:vulkan"

import "core:container/small_array"

Glyph :: struct {
	id:               i32,
	x, y:             i32,
	width, height:    i32,
	xoffset, yoffset: i32,
	xadvance:         i32,
}

Kerning :: struct {
	first, second: i32,
	amount:        i32,
}

BMFont_Info :: struct {
	face: string,
	size: i32,

	// ... other fields if needed
}

BMFont_Common :: struct {
	lineHeight:     i32,
	base:           i32,
	scaleW, scaleH: i32,
	// pages, etc.
}

BMFont :: struct {
	info:     BMFont_Info,
	common:   BMFont_Common,
	pages:    []string,
	chars:    []Glyph,
	kernings: []Kerning,
	glyphMap: map[rune]Glyph,
	texture:  GPUTexture,
}

bmfont_json_load :: proc(
	path: string,
	cb: vk.CommandBuffer,
	alloc := context.allocator,
) -> (
	font: BMFont,
) {
	assert(os.exists(path))

	fileBytes, osErr := os.read_entire_file_from_path(path, context.temp_allocator)
	if osErr != nil do log.fatalf("[UI] error opening BMFONT JSON file: %s", os.error_string(osErr))

	when ODIN_DEBUG {
		parsed, jsonErr := json.parse(fileBytes, allocator = context.temp_allocator)
		if jsonErr != nil do log.fatalf("[UI] error parsing BMFONT json: %s", fmt.enum_value_to_string(jsonErr))
	}


	unmarshallErr := json.unmarshal(fileBytes, &font, allocator = context.temp_allocator)
	if unmarshallErr != nil do log.fatalf("[UI] error unmarshalling BMFONT json: %s", fmt.enum_value_to_string(unmarshallErr))

	assert(len(font.pages) > 0)
	pngPath := font.pages[0]

	dir := filepath.dir(path, context.temp_allocator)
	pngFinalPath := filepath.join({dir, pngPath}, context.temp_allocator)

	pngFinalPathCString := strings.clone_to_cstring(pngFinalPath, context.temp_allocator)
	assert(os.exists(pngFinalPath))

	inputs: ImageLoaderInputs
	DESIRED_CHANNELS :: 4
	inputs.data = stbImage.load(
		pngFinalPathCString,
		&inputs.width,
		&inputs.height,
		nil,
		DESIRED_CHANNELS,
	)
	assert(inputs.data != nil)
	defer stbImage.image_free(inputs.data)

	inputs.magFilter = .LINEAR
	inputs.minFilter = .LINEAR
	inputs.channels = DESIRED_CHANNELS
	font.texture = load_gltf_image(inputs, cb)

	font.glyphMap = make(map[rune]Glyph, len(font.chars), alloc)
	for &g in font.chars {
		font.glyphMap[rune(g.id)] = g
	}

	return font
}
bmfont_destroy :: proc(f: BMFont) {
	delete(f.glyphMap)
	view := f.texture.descriptor.imageView
	if view != {} do vk.DestroyImageView(vkDevice, view, nil)

	sampler := f.texture.descriptor.sampler
	if sampler != {} do vk.DestroySampler(vkDevice, sampler, nil)

	image := f.texture.image
	if image != {} do vma.destroy_image(vkAllocator, image, f.texture.allocation)

}
TextVertex :: struct {
	pos: [2]f32,
	uv:  [2]f32,
}
TextPushConstants :: struct #align (16) {
	color:   [4]f32,
	pxRange: f32,
}


MAX_TEXT_VERTS :: 4096 * 6
VkTextFont :: struct {
	color:       [4]f32,
	descriptor:  vk.DescriptorImageInfo,
	vertices:    small_array.Small_Array(MAX_TEXT_VERTS, TextVertex),
	face:        string,
	firstVertex: u32,
	vertexCount: u32,
}

MAX_TEXT_FONTS :: 5
vkTextFonts: small_array.Small_Array(MAX_TEXT_FONTS, VkTextFont)

vkTextVertexBuffer: vk.Buffer
vkTextVertexAlloc: vma.Allocation


vk_ui_init :: proc() -> (p: PipelineData) {
	vk_chk(
		vma.create_buffer(
			vkAllocator,
			{
				sType = .BUFFER_CREATE_INFO,
				size = vk.DeviceSize(MAX_TEXT_FONTS * MAX_TEXT_VERTS * size_of(TextVertex)),
				usage = {.VERTEX_BUFFER},
			},
			{flags = {.Host_Access_Sequential_Write, .Mapped}, usage = .Auto},
			&vkTextVertexBuffer,
			&vkTextVertexAlloc,
			nil,
		),
	)


	layoutBindings := [?]vk.DescriptorSetLayoutBinding {
		{
			binding = 0,
			descriptorType = .COMBINED_IMAGE_SAMPLER,
			descriptorCount = 1,
			stageFlags = {.FRAGMENT},
		},
	}
	vk_chk(
		vk.CreateDescriptorSetLayout(
			vkDevice,
			&{
				sType = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
				bindingCount = len(layoutBindings),
				pBindings = raw_data(layoutBindings[:]),
				flags = {.PUSH_DESCRIPTOR_KHR},
			},
			nil,
			&p.descriptorSetLayout,
		),
	)

	assert(p.descriptorSetLayout != {})
	pushRange := vk.PushConstantRange {
		stageFlags = {.VERTEX, .FRAGMENT},
		offset     = 0,
		size       = size_of(TextPushConstants),
	}
	vk_chk(
		vk.CreatePipelineLayout(
			vkDevice,
			&{
				sType = .PIPELINE_LAYOUT_CREATE_INFO,
				setLayoutCount = 1,
				pSetLayouts = &p.descriptorSetLayout,
				pushConstantRangeCount = 1,
				pPushConstantRanges = &pushRange,
			},
			nil,
			&p.layout,
		),
	)
	assert(p.layout != {})

	vertexInputBindings := [?]vk.VertexInputBindingDescription {
		{binding = 0, stride = size_of(TextVertex), inputRate = .VERTEX},
	}
	vertexAttributes := [?]vk.VertexInputAttributeDescription {
		{location = 0, binding = 0, format = .R32G32_SFLOAT, offset = 0},
		{
			location = 1,
			binding = 0,
			format = .R32G32_SFLOAT,
			offset = u32(offset_of(TextVertex, uv)),
		},
	}

	dynamicStates := [?]vk.DynamicState{.VIEWPORT, .SCISSOR}


	VERT_SPV :: #load("../build/shader-binaries/text.vertex.spv")
	FRAG_SPV :: #load("../build/shader-binaries/text.fragment.spv")

	vertModule := create_shader_module(vkDevice, VERT_SPV)
	fragModule := create_shader_module(vkDevice, FRAG_SPV)

	defer vk.DestroyShaderModule(vkDevice, vertModule, nil)
	defer vk.DestroyShaderModule(vkDevice, fragModule, nil)

	shaderStages := [?]vk.PipelineShaderStageCreateInfo {
		{
			sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
			stage = {.VERTEX},
			module = vertModule,
			pName = "main",
		},
		{
			sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
			stage = {.FRAGMENT},
			module = fragModule,
			pName = "main",
		},
	}


	pipelineCi := vk.GraphicsPipelineCreateInfo {
		sType               = .GRAPHICS_PIPELINE_CREATE_INFO,
		stageCount          = len(shaderStages),
		pNext               = &vk.PipelineRenderingCreateInfo {
			sType = .PIPELINE_RENDERING_CREATE_INFO,
			colorAttachmentCount = 1,
			pColorAttachmentFormats = &swapchainImageFormat,
			depthAttachmentFormat = depthFormat,
		},
		pStages             = raw_data(shaderStages[:]),
		pVertexInputState   = &vk.PipelineVertexInputStateCreateInfo {
			sType = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
			vertexBindingDescriptionCount = len(vertexInputBindings),
			pVertexBindingDescriptions = raw_data(vertexInputBindings[:]),
			vertexAttributeDescriptionCount = len(vertexAttributes),
			pVertexAttributeDescriptions = raw_data(vertexAttributes[:]),
		},
		pInputAssemblyState = &vk.PipelineInputAssemblyStateCreateInfo {
			sType = .PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
			topology = .TRIANGLE_LIST,
		},
		pViewportState      = &vk.PipelineViewportStateCreateInfo {
			sType = .PIPELINE_VIEWPORT_STATE_CREATE_INFO,
			viewportCount = 1,
			scissorCount = 1,
		},
		pRasterizationState = &vk.PipelineRasterizationStateCreateInfo {
			sType = .PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
			polygonMode = .FILL,
			cullMode = {},
			frontFace = .COUNTER_CLOCKWISE,
			lineWidth = 1.0,
		},
		pMultisampleState   = &vk.PipelineMultisampleStateCreateInfo {
			sType = .PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
			rasterizationSamples = {._1},
		},
		pDepthStencilState  = &vk.PipelineDepthStencilStateCreateInfo {
			sType = .PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
			depthTestEnable = false,
			depthWriteEnable = false,
			depthCompareOp = .LESS_OR_EQUAL,
		},
		pColorBlendState    = &vk.PipelineColorBlendStateCreateInfo {
			sType = .PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
			logicOpEnable = false,
			attachmentCount = 1,
			pAttachments = &vk.PipelineColorBlendAttachmentState {
				blendEnable = true,
				srcColorBlendFactor = .SRC_ALPHA,
				dstColorBlendFactor = .ONE_MINUS_SRC_ALPHA,
				colorBlendOp = .ADD,
				srcAlphaBlendFactor = .ONE,
				dstAlphaBlendFactor = .ONE_MINUS_SRC_ALPHA,
				alphaBlendOp = .ADD,
				colorWriteMask = {.R, .G, .B, .A},
			},
		},
		pDynamicState       = &{
			sType = .PIPELINE_DYNAMIC_STATE_CREATE_INFO,
			dynamicStateCount = len(dynamicStates),
			pDynamicStates = raw_data(dynamicStates[:]),
		},
		layout              = p.layout,
		subpass             = 0,
	}

	vk_chk(vk.CreateGraphicsPipelines(vkDevice, 0, 1, &pipelineCi, nil, &p.graphicsPipeline))
	return p
}
ui_frame_reset :: proc() {
	small_array.clear(&vkTextFonts)
}
ui_add_text :: proc(str: string, font: BMFont, fontSize: f32, posX, posY: f32, color: [4]f32) {
	assert(font.info.size != 0)
	assert(font.glyphMap != nil)
	assert(fontSize != 0)

	scale := fontSize / f32(font.info.size)

	penX := posX
	penY := posY

	prevId: i32 = -1

	existingFontIdx := -1
	for vkTextFont, i in small_array.slice(&vkTextFonts) {
		if font.info.face == vkTextFont.face {
			existingFontIdx = i
			break
		}
	}

	vkTextFont: ^VkTextFont
	if existingFontIdx != -1 {
		vkTextFont = small_array.get_ptr(&vkTextFonts, existingFontIdx)
	} else {
		idx := small_array.len(vkTextFonts)
		small_array.append_elem(&vkTextFonts, VkTextFont{})
		vkTextFont = small_array.get_ptr(&vkTextFonts, idx)

	}

	when ODIN_DEBUG {
		_, found := font.glyphMap['?']
		assert(found)
	}

	vkTextFont.color = color
	vkTextFont.face = font.info.face
	vkTextFont.descriptor = font.texture.descriptor


	for r in str {
		if r == '\n' {
			penX = posX
			penY += f32(font.common.lineHeight) * scale
			continue
		}
		if r == ' ' || r == '\t' {
			penX += f32(font.common.base) * scale * 0.5
			continue
		}

		glyph, glyphFound := font.glyphMap[rune(r)]
		if !glyphFound do glyph = font.glyphMap['?'] or_continue

		left := penX + f32(glyph.xoffset) * scale
		right := left + f32(glyph.width) * scale
		top := penY + f32(glyph.yoffset) * scale
		bottom := top + f32(glyph.height) * scale


		assert(font.common.scaleW != 0)
		assert(font.common.scaleH != 0)

		uvLeft := f32(glyph.x) / f32(font.common.scaleW)
		uvTop := f32(glyph.y) / f32(font.common.scaleH)
		uvBottom := f32(glyph.y + glyph.height) / f32(font.common.scaleH)
		uvRight := f32(glyph.x + glyph.width) / f32(font.common.scaleW)

		w := f32(screenWidth)
		h := f32(screenHeight)

		leftNdc := (left / w * 2 - 1)
		rightNdc := (right / w * 2 - 1)
		topNdc := 1 - (top / h) * 2
		bottomNdc := 1 - (bottom / h) * 2


		small_array.append(
			&vkTextFont.vertices,
			TextVertex{{leftNdc, bottomNdc}, {uvLeft, uvTop}},
			TextVertex{{rightNdc, bottomNdc}, {uvRight, uvTop}},
			TextVertex{{rightNdc, topNdc}, {uvRight, uvBottom}},
			TextVertex{{leftNdc, bottomNdc}, {uvLeft, uvTop}},
			TextVertex{{rightNdc, topNdc}, {uvRight, uvBottom}},
			TextVertex{{leftNdc, topNdc}, {uvLeft, uvBottom}},
		)
		penX += f32(glyph.xadvance) * scale

		if prevId >= 0 {
			keringAmount: i32 = 0
			for kering in font.kernings {
				if kering.first == prevId && kering.second == glyph.id {
					keringAmount = kering.amount
				}
			}
			penX += f32(keringAmount) * scale
		}

		prevId = glyph.id
	}

}
ui_render_text :: proc(cb: vk.CommandBuffer, textP: PipelineData) {
	if small_array.len(vkTextFonts) == 0 do return

	vk.CmdSetViewport(
		cb,
		0,
		1,
		&vk.Viewport {
			x = 0,
			y = 0,
			width = f32(screenWidth),
			height = f32(screenHeight),
			minDepth = 0,
			maxDepth = 1,
		},
	)
	vk.CmdSetScissor(cb, 0, 1, &vk.Rect2D{offset = {0, 0}, extent = {screenWidth, screenHeight}})

	vk.CmdBindPipeline(cb, .GRAPHICS, textP.graphicsPipeline)
	size := vk.DeviceSize(0)

	offset := vk.DeviceSize(0)
	vk.CmdBindVertexBuffers(cb, 0, 1, &vkTextVertexBuffer, &offset)

	// Map once
	ptr: rawptr
	vk_chk(vma.map_memory(vkAllocator, vkTextVertexAlloc, &ptr))

	basePtr := (^TextVertex)(ptr)
	runningVertexOffset: u32 = 0

	for &font in small_array.slice(&vkTextFonts) {
		verts := small_array.slice(&font.vertices)
		count := u32(len(verts))
		if count == 0 do continue

		font.firstVertex = runningVertexOffset
		font.vertexCount = count

		mem.copy(basePtr, raw_data(verts), int(count) * size_of(TextVertex))
		basePtr = mem.ptr_offset(basePtr, int(count) * size_of(TextVertex))

		runningVertexOffset += count
	}

	vma.unmap_memory(vkAllocator, vkTextVertexAlloc)

	for &font in small_array.slice(&vkTextFonts) {
		if font.vertexCount == 0 do continue

		write := vk.WriteDescriptorSet {
			sType           = .WRITE_DESCRIPTOR_SET,
			dstBinding      = 0,
			descriptorCount = 1,
			descriptorType  = .COMBINED_IMAGE_SAMPLER,
			pImageInfo      = &font.descriptor,
		}

		vk.CmdPushDescriptorSetKHR(cb, .GRAPHICS, textP.layout, 0, 1, &write)

		push := TextPushConstants {
			color   = font.color,
			pxRange = 6.0,
		}

		vk.CmdPushConstants(
			cb,
			textP.layout,
			{.VERTEX, .FRAGMENT},
			0,
			size_of(TextPushConstants),
			&push,
		)

		vk.CmdDraw(cb, font.vertexCount, 1, font.firstVertex, 0)
	}
}
vk_ui_destroy :: proc(textP: PipelineData) {
	if vkTextVertexBuffer != {} {
		vma.destroy_buffer(vkAllocator, vkTextVertexBuffer, vkTextVertexAlloc)
	}
	if textP.graphicsPipeline != {} {
		vk.DestroyPipeline(vkDevice, textP.graphicsPipeline, nil)
	}
	if textP.layout != {} {
		vk.DestroyPipelineLayout(vkDevice, textP.layout, nil)
	}
	if textP.descriptorSetLayout != {} {
		vk.DestroyDescriptorSetLayout(vkDevice, textP.descriptorSetLayout, nil)
	}
}
