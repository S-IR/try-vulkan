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

	for r in str {

		if r == '\n' {
			break // only horizontal width
		}

		if r == ' ' || r == '\t' {
			width += font.common.base / 2
			continue
		}

		glyph, found := font.glyphMap[rune(r)]
		if !found do glyph = font.glyphMap['?'] or_continue

		width += glyph.xadvance

		if prevId >= 0 {
			for k in font.kernings {
				if k.first == prevId && k.second == glyph.id {
					width += k.amount
					break
				}
			}
		}

		prevId = glyph.id
	}

	return width
}

mu_text_height :: proc(muFont: mu.Font) -> i32 {
	font := (^BMFont)(muFont)
	assert(font != nil)
	return font.common.lineHeight
}


clayMemory := [dynamic]u8{}
muCtx: mu.Context
mu_init :: proc(font: ^BMFont) {
	mu.init(&muCtx)
	muCtx.text_width = mu_text_width
	muCtx.text_height = mu_text_height
	mu.default_style.font = mu.Font(font)
	muCtx.style.font = mu.Font(font)
}

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
	if mu.begin_window(&muCtx, "My window", {0, 0, 256, 256}) {

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
	assert(vkUIVertexBuffer != {})
	offset := vk.DeviceSize(0)
	vk.CmdBindVertexBuffers(cb, 0, 1, &vkUIVertexBuffer, &offset)

	ptr: ^TextVertex
	vk_chk(vma.map_memory(vkAllocator, vkUIVertexAlloc, (^rawptr)(&ptr)))
	assert(ptr != nil)
	defer vma.unmap_memory(vkAllocator, vkUIVertexAlloc)


	currentVertexOffset: u32 = 0
	currentByteOffset: int = 0

	commandBacking: ^mu.Command
	for variant in mu.next_command_iterator(&muCtx, &commandBacking) {
		switch cmd in variant {
		case ^mu.Command_Text:
			actualFont := (^BMFont)(cmd.font)
			assert(actualFont != nil)

			writtenBytes, vertexCount := ui_write_font_verts(
				cmd.str,
				actualFont^,
				f32(cmd.size),
				f32(cmd.pos.x),
				f32(cmd.pos.y),
				ptr,
				currentByteOffset,
			)

			ptr = mem.ptr_offset(ptr, vertexCount * size_of(TextVertex))

			currentByteOffset += writtenBytes
			currentVertexOffset += u32(vertexCount)

			vk.CmdPushDescriptorSet(
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

		// vk.CmdDraw(cb, vertexCount, 1, currentVertexOffset - u32(vertexCount), 0)

		case ^mu.Command_Rect:
			fmt.println("r_draw_rect(cmd.rect, cmd.color)")
		case ^mu.Command_Icon:
			fmt.println("r_draw_icon(cmd.id, cmd.rect, cmd.color)")
		case ^mu.Command_Clip:
			fmt.println("r_set_clip_rect(cmd.rect)")
		case ^mu.Command_Jump:
			fmt.println("unreachable()")
		}
	}

}
