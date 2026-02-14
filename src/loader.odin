package main
import vk "vendor:vulkan"

loader_command_buffer_create :: proc() -> (cb: vk.CommandBuffer, fence: vk.Fence) {
	vk_chk(
		vk.AllocateCommandBuffers(
			vkDevice,
			&vk.CommandBufferAllocateInfo {
				sType = .COMMAND_BUFFER_ALLOCATE_INFO,
				commandPool = vkCommandPool,
				commandBufferCount = 1,
			},
			&cb,
		),
	)
	vk_chk(
		vk.BeginCommandBuffer(
			cb,
			&vk.CommandBufferBeginInfo {
				sType = .COMMAND_BUFFER_BEGIN_INFO,
				flags = {.ONE_TIME_SUBMIT},
			},
		),
	)

	vk_chk(vk.CreateFence(vkDevice, &{sType = .FENCE_CREATE_INFO}, nil, &fence))
	return cb, fence
}
loader_command_buffer_destroy :: proc(cb: vk.CommandBuffer, fence: vk.Fence) {

	vk_chk(vk.EndCommandBuffer(cb))
	tempCbArr := [?]vk.CommandBuffer{cb}

	vk_chk(
		vk.QueueSubmit(
			vkQueue,
			1,
			&vk.SubmitInfo {
				sType = .SUBMIT_INFO,
				commandBufferCount = len(tempCbArr),
				pCommandBuffers = raw_data(tempCbArr[:]),
			},
			fence,
		),
	)
	tempFenceArr := [?]vk.Fence{fence}
	vk_chk(
		vk.WaitForFences(vkDevice, len(tempFenceArr), raw_data(tempFenceArr[:]), true, max(u64)),
	)

	vk.FreeCommandBuffers(vkDevice, vkCommandPool, len(tempCbArr), raw_data(tempCbArr[:]))
	vk.DestroyFence(vkDevice, fence, nil)

}
