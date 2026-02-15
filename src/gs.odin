package main
import "../modules/vma"
import "core:container/small_array"
import "core:fmt"
import sdl "vendor:sdl3"
import vk "vendor:vulkan"

dt: f64


window: ^sdl.Window
screenWidth: u32 = 1280
screenHeight: u32 = 720

MAX_FRAMES_IN_FLIGHT: u32 : 2

swapchainImageFormat: vk.Format = .B8G8R8A8_SRGB
swapchainColorSpace: vk.ColorSpaceKHR = .SRGB_NONLINEAR
depthFormat: vk.Format = .UNDEFINED

updateSwapchain := false
vkInstance: vk.Instance
vkPhysicalDevice: vk.PhysicalDevice
vkDevice: vk.Device
vkQueue: vk.Queue
vkAllocator: vma.Allocator
vkSurface: vk.SurfaceKHR
vkSwapchain: vk.SwapchainKHR
vkImageCount: u32
vkSwapchainImages: [dynamic]vk.Image = nil
vkSwpachainImageViews: [dynamic]vk.ImageView = nil
vkDepthImage: vk.Image
vmaDepthStencilAlloc: vma.Allocation
vkDepthImageView: vk.ImageView

vkGraphicsQueueFamilyIndex: u32 = 0
ShaderData :: struct {
	projection: matrix[4, 4]f32,
	view:       matrix[4, 4]f32,
	lightPos:   [4]f32,
}
ShaderDataBuffer :: struct {
	allocation:    vma.Allocation,
	buffer:        vk.Buffer,
	deviceAddress: vk.DeviceAddress,
	mapped:        rawptr,
}

// descriptorSets: [MAX_FRAMES_IN_FLIGHT]vk.DescriptorSet

shaderDataBuffers := [MAX_FRAMES_IN_FLIGHT]ShaderDataBuffer{}
drawCommandBuffers := [MAX_FRAMES_IN_FLIGHT]vk.CommandBuffer{}
fences := [MAX_FRAMES_IN_FLIGHT]vk.Fence{}
presentSemaphores := [MAX_FRAMES_IN_FLIGHT]vk.Semaphore{}
vkRenderSemaphores: []vk.Semaphore = nil
vkCommandPool: vk.CommandPool
vkCommandBuffers := [MAX_FRAMES_IN_FLIGHT]vk.CommandBuffer{}

// vBuffer: vk.Buffer
// vertexBufferSize := 0
// indicesCount: u32 = 0
// vBufferAllocation: vma.Allocation


frameIndex: u32 = 0
imageIndex: u32 = 0
// textures: [3]texture
textureDescriptors: [3]vk.DescriptorImageInfo
// descriptorSetLayoutTex: vk.DescriptorSetLayout
// descriptorPool: vk.DescriptorPool
// descriptorSetTex: vk.DescriptorSet

// pipelineLayout: vk.PipelineLayout
// graphicsPipeline: vk.Pipeline

VK_BUFFER_POOL_MAX_ALLOCATIONS :: 1024

VkBufferPoolElem :: struct {
	buffer: vk.Buffer,
	alloc:  vma.Allocation,
}
vkBufferPool: small_array.Small_Array(VK_BUFFER_POOL_MAX_ALLOCATIONS, VkBufferPoolElem) = {}
vk_buffer_pool_clear :: proc() {
	for e, i in small_array.slice(&vkBufferPool) {
		vma.unmap_memory(vkAllocator, e.alloc)
		vma.destroy_buffer(vkAllocator, e.buffer, e.alloc)
	}
	small_array.clear(&vkBufferPool)
}
