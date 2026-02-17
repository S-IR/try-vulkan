package main
import "../modules/vma"
import "core:fmt"
import "core:mem"
import mu "vendor:microui"
import sdl "vendor:sdl3"
import vk "vendor:vulkan"

mu_text_width :: proc(muFont: mu.Font, str: string) -> i32 {

	font := (^BMFont)(muFont)
	assert(font != nil)
	width: i32 = 0
	prevId: i32 = -1
	scale := i32(MU_FONT_SIZE) / i32(font.info.size)

	for r in str {
		glyph, glyphFound := font.glyphMap[rune(r)]
		if !glyphFound do glyph = font.glyphMap['?'] or_continue


		width += glyph.xadvance * scale

		if prevId >= 0 {
			keringAmount: i32 = 0
			for kering in font.kernings {
				if kering.first == prevId && kering.second == glyph.id {
					keringAmount = kering.amount
				}
			}
			width += keringAmount * scale
		}

		prevId = glyph.id
	}

	return width
}

mu_text_height :: proc(muFont: mu.Font) -> i32 {
	font := (^BMFont)(muFont)
	assert(font != nil)
	scale := i32(MU_FONT_SIZE) / i32(font.info.size)
	return font.common.lineHeight * scale
}


muCtx: mu.Context
mu_init :: proc(font: ^BMFont) {
	mu.init(&muCtx)
	muCtx.text_width = mu_text_width
	muCtx.text_height = mu_text_height
	mu.default_style.font = mu.Font(font)
	muCtx.style.font = mu.Font(font)
}
MU_FONT_SIZE :: 32
mu_layout :: proc() {
	mouseX, mouseY: f32
	mouseState := sdl.GetMouseState(&mouseX, &mouseY)

	if .LEFT in mouseState {
		mu.input_mouse_down(&muCtx, i32(mouseX), i32(mouseY), .LEFT)
	} else {
		mu.input_mouse_up(&muCtx, i32(mouseX), i32(mouseY), .LEFT)
	}

	if .RIGHT in mouseState {
		mu.input_mouse_down(&muCtx, i32(mouseX), i32(mouseY), .RIGHT)
	} else {
		mu.input_mouse_up(&muCtx, i32(mouseX), i32(mouseY), .RIGHT)
	}

	mu.input_mouse_move(&muCtx, i32(mouseX), i32(mouseY))


	mu.begin(&muCtx)
	if mu.begin_window(&muCtx, "My window", {10, 10, 256, 256}) {

		widths := [2]i32{60, -1}
		mu.layout_row(&muCtx, widths[:], 0)

		mu.label(&muCtx, "First:")
		if .ACTIVE in (mu.button(&muCtx, "Button1")) {
			fmt.printf("Button1 pressed\n")
		}

		mu.label(&muCtx, "Second:")
		if .ACTIVE in mu.button(&muCtx, "Button2") {
			mu.open_popup(&muCtx, "My Popup")
		}

		if (mu.begin_popup(&muCtx, "My Popup")) {
			mu.label(&muCtx, "Hello world!")
			mu.end_popup(&muCtx)
		}

		mu.end_window(&muCtx)

	}
	mu.end(&muCtx)


}
mu_render_ui :: proc(cb: vk.CommandBuffer, uiP: PipelineData) {
	vk.CmdBindPipeline(cb, .GRAPHICS, uiP.graphicsPipeline)
	vertexBuffer := vkUIVertexBuffers[frameIndex]
	alloc := vkUIVertexAllocs[frameIndex]
	assert(vertexBuffer != {})
	offset := vk.DeviceSize(0)
	vk.CmdBindVertexBuffers(cb, 0, 1, &vertexBuffer, &offset)

	ptr: ^u8
	vk_chk(vma.map_memory(vkAllocator, alloc, (^rawptr)(&ptr)))
	assert(ptr != nil)
	defer vma.unmap_memory(vkAllocator, alloc)


	currentVertexOffset: u32 = 0
	currentByteOffset: int = 0

	commandBacking: ^mu.Command
	for variant in mu.next_command_iterator(&muCtx, &commandBacking) {
		switch cmd in variant {
		case ^mu.Command_Text:
			actualFont := (^BMFont)(cmd.font)
			assert(actualFont != nil)
			fontSize := f32(MU_FONT_SIZE)

			writtenBytes, vertexCount := ui_write_font_verts(
				cmd.str,
				actualFont^,
				fontSize,
				f32(cmd.pos.x),
				f32(cmd.pos.y),
				ptr,
				currentByteOffset,
			)

			ptr = mem.ptr_offset(ptr, vertexCount * size_of(TextVertex))

			currentByteOffset += writtenBytes
			assert(actualFont.texture != {})
			assert(actualFont.texture.descriptor != {})

			vk.CmdPushDescriptorSetKHR(
				cb,
				.GRAPHICS,
				uiP.layout,
				0,
				1,
				&vk.WriteDescriptorSet {
					sType = .WRITE_DESCRIPTOR_SET,
					dstBinding = 0,
					descriptorCount = 1,
					descriptorType = .COMBINED_IMAGE_SAMPLER,
					pImageInfo = &actualFont.texture.descriptor,
				},
			)

			push := UIPushConstants {
				color   = [4]f32 {
					f32(cmd.color.r) / f32(max(u8)),
					f32(cmd.color.g) / f32(max(u8)),
					f32(cmd.color.b) / f32(max(u8)),
					f32(cmd.color.a) / f32(max(u8)),
				},
				pxRange = 6.0,
				mode    = .Text,
			}
			vk.CmdPushConstants(
				cb,
				uiP.layout,
				{.VERTEX, .FRAGMENT},
				0,
				size_of(UIPushConstants),
				&push,
			)
			vma.flush_allocation(vkAllocator, alloc, 0, vk.DeviceSize(currentByteOffset))

			vk.CmdDraw(cb, vertexCount, 1, currentVertexOffset, 0)
			currentVertexOffset += u32(vertexCount)


		case ^mu.Command_Rect:
			left := f32(cmd.rect.x)
			right := left + f32(cmd.rect.w)
			top := f32(cmd.rect.y)
			bottom := top + f32(cmd.rect.h)

			screenWF32 := f32(screenWidth)
			screenHF32 := f32(screenHeight)

			leftNdc := ((left - (screenWF32 / 2)) * 2 / screenWF32)
			rightNdc := ((right - (screenWF32 / 2)) * 2 / screenWF32)
			topNdc := ((top - (screenHF32 / 2)) * 2 / screenHF32)
			bottomNdc := ((bottom - (screenHF32 / 2)) * 2 / screenHF32)

			rectVertices := [?]TextVertex {
				TextVertex{{leftNdc, bottomNdc}, {}},
				TextVertex{{rightNdc, bottomNdc}, {}},
				TextVertex{{rightNdc, topNdc}, {}},
				TextVertex{{leftNdc, bottomNdc}, {}},
				TextVertex{{rightNdc, topNdc}, {}},
				TextVertex{{leftNdc, topNdc}, {}},
			}

			sizeToWrite := len(rectVertices) * size_of(rectVertices[0])
			mem.copy(ptr, raw_data(rectVertices[:]), sizeToWrite)
			ptr = mem.ptr_offset(ptr, sizeToWrite)

			vk.CmdPushDescriptorSetKHR(
				cb,
				.GRAPHICS,
				uiP.layout,
				0,
				1,
				&vk.WriteDescriptorSet {
					sType = .WRITE_DESCRIPTOR_SET,
					dstBinding = 0,
					descriptorCount = 1,
					descriptorType = .COMBINED_IMAGE_SAMPLER,
					pImageInfo = &vkDummyTexture.descriptor,
				},
			)

			push := UIPushConstants {
				color   = [4]f32 {
					f32(cmd.color.r) / f32(max(u8)),
					f32(cmd.color.g) / f32(max(u8)),
					f32(cmd.color.b) / f32(max(u8)),
					f32(cmd.color.a) / f32(max(u8)),
				},
				pxRange = 6.0,
				mode    = .Solid,
			}
			vk.CmdPushConstants(
				cb,
				uiP.layout,
				{.VERTEX, .FRAGMENT},
				0,
				size_of(UIPushConstants),
				&push,
			)
			vma.flush_allocation(vkAllocator, alloc, 0, vk.DeviceSize(currentByteOffset))

			vk.CmdDraw(cb, len(rectVertices), 1, currentVertexOffset, 0)
			currentVertexOffset += len(rectVertices)
			currentByteOffset += sizeToWrite
		case ^mu.Command_Icon:
		// fmt.println("r_draw_icon(cmd.id, cmd.rect, cmd.color)")
		case ^mu.Command_Clip:
			clipX := u32(cmd.rect.x)
			clipY := u32(cmd.rect.y)
			clipW := u32(cmd.rect.w)
			clipH := u32(cmd.rect.h)

			scissor := vk.Rect2D {
				offset = vk.Offset2D{x = i32(clipX), y = i32(clipY)},
				extent = vk.Extent2D{width = clipW, height = clipH},
			}

			vk.CmdSetScissor(cb, 0, 1, &scissor)
		case ^mu.Command_Jump:
			fmt.println("unreachable()")
		}
	}

}
