package main
import ktx "../modules/libktx"
import "../modules/vma"
import sdl "vendor:sdl3"
import vk "vendor:vulkan"

window: ^sdl.Window
screenWidth: u32 = 1280
screenHeight: u32 = 720

MAX_FRAMES_IN_FLIGHT: u32 : 2

swapchainImageFormat: vk.Format = .B8G8R8A8_SRGB

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
vkSwapchainImages: []vk.Image = nil
vkSwpachainImageViews: []vk.ImageView = nil
vkDepthImage: vk.Image
vmaDepthStencilAlloc: vma.Allocation
vkDepthImageView: vk.ImageView

ShaderData :: struct {
	projection: matrix[4, 4]f32,
	view:       matrix[4, 4]f32,
	model:      [3]matrix[4, 4]f32,
	lightPos:   [4]f32,
	selected:   u32,
}
ShaderDataBuffer :: struct {
	allocation:    vma.Allocation,
	buffer:        vk.Buffer,
	deviceAddress: vk.DeviceAddress,
	mapped:        rawptr,
}
shaderDataBuffers := [MAX_FRAMES_IN_FLIGHT]ShaderDataBuffer{}
commandBuffers := [MAX_FRAMES_IN_FLIGHT]vk.CommandBuffer{}
fences := [MAX_FRAMES_IN_FLIGHT]vk.Fence{}
presentSemaphores := [MAX_FRAMES_IN_FLIGHT]vk.Semaphore{}
renderSemaphores: []vk.Semaphore = nil
vkCommandPool: vk.CommandPool
vkCommandBuffers := [MAX_FRAMES_IN_FLIGHT]vk.CommandBuffer{}

vBuffer: vk.Buffer
vertexBufferSize := 0
indicesCount: u32 = 0
vBufferAllocation: vma.Allocation

texture :: struct {
	image:      vk.Image,
	view:       vk.ImageView,
	sampler:    vk.Sampler,
	allocation: vma.Allocation,
}

frameIndex: u32 = 0
imageIndex: u32 = 0
textures: [3]texture
textureDescriptors: [3]vk.DescriptorImageInfo
descriptorSetLayoutTex: vk.DescriptorSetLayout
descriptorPool: vk.DescriptorPool
descriptorSetTex: vk.DescriptorSet

pipelineLayout: vk.PipelineLayout
graphicsPipeline: vk.Pipeline
