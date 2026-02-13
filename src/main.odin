package main

import "../modules/vma"
import "core:fmt"
import "core:log"
import la "core:math/linalg"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"
import "obj"
import sdl "vendor:sdl3"
import image "vendor:stb/image"
import vk "vendor:vulkan"

MAX_TEXTURES :: 8


main :: proc() {

	sdl_ensure(sdl.Init({.VIDEO, .EVENTS}))
	window = sdl.CreateWindow(
		"How to vulkan",
		i32(screenWidth),
		i32(screenHeight),
		{.RESIZABLE, .VULKAN},
	)
	sdl_ensure(window != nil)
	defer sdl.DestroyWindow(window)
	sdl.SetLogPriorities(.WARN)

	vulkan_init()
	defer vulkan_cleanup()

	pipeline_init()
	quit := false
	prevScreenWidth := screenWidth
	prevScreenHeight := screenHeight

	e: sdl.Event


	lastFrameTime := time.now()
	camera := Camera_new()
	for !quit {

		defer free_all(context.temp_allocator)

		defer {
			frameEnd := time.now()
			frameDuration := time.diff(frameEnd, lastFrameTime)

			dt = time.duration_seconds(time.since(lastFrameTime))
			lastFrameTime = time.now()
		}


		for sdl.PollEvent(&e) {

			#partial switch e.type {
			case .QUIT:
				quit = true
				break
			case .KEY_DOWN:
				switch e.key.key {
				case sdl.K_ESCAPE:
					quit = true
				case sdl.K_F11:
					flags := sdl.GetWindowFlags(window)
					if .FULLSCREEN in flags {
						sdl.SetWindowFullscreen(window, false)
					} else {
						sdl.SetWindowFullscreen(window, true)
					}


				}

			case .WINDOW_RESIZED:
				screenWidth, screenHeight = u32(e.window.data1), u32(e.window.data2)
			case .MOUSE_MOTION:
				Camera_process_mouse_movement(&camera, e.motion.xrel, e.motion.yrel)
			case:
				continue
			}

			if prevScreenWidth != screenWidth || prevScreenHeight != screenHeight {
				sdl.SetWindowSize(window, i32(screenWidth), i32(screenHeight))

				updateSwapchain = true
				vulkan_update_swapchain()

				sdl.SyncWindow(window)
				prevScreenWidth = screenWidth
				prevScreenHeight = screenHeight
			}

		}
		Camera_process_keyboard_movement(&camera)

		vulkan_update_swapchain()
		vulkan_render(&camera)
	}
}
vulkan_init :: proc() {
	sdl.Vulkan_LoadLibrary(nil)
	vkGetProc := sdl.Vulkan_GetVkGetInstanceProcAddr()
	assert(vkGetProc != nil)
	vk.load_proc_addresses_global(rawptr(vkGetProc))

	appInfo := vk.ApplicationInfo {
		sType            = .APPLICATION_INFO,
		pApplicationName = "How to Vulkan",
		apiVersion       = vk.API_VERSION_1_3,
	}
	instanceExtensionCount: u32
	extensions := sdl.Vulkan_GetInstanceExtensions(&instanceExtensionCount)

	instanceCI := vk.InstanceCreateInfo {
		sType                   = .INSTANCE_CREATE_INFO,
		pApplicationInfo        = &appInfo,
		enabledExtensionCount   = instanceExtensionCount,
		ppEnabledExtensionNames = extensions,
	}
	when ODIN_DEBUG {
		layers := [?]cstring{"VK_LAYER_KHRONOS_validation"}
		instanceCI.enabledLayerCount = u32(len(layers))
		instanceCI.ppEnabledLayerNames = raw_data(layers[:])
	}

	vk_chk(vk.CreateInstance(&instanceCI, nil, &vkInstance))
	vk.load_proc_addresses_instance(vkInstance)

	deviceCount: u32 = 0
	vk_chk(vk.EnumeratePhysicalDevices(vkInstance, &deviceCount, nil))
	devices := make([]vk.PhysicalDevice, deviceCount, context.temp_allocator)
	if deviceCount == 0 {
		fmt.eprintln("cannot find any device supporting our given Vulkan requirements")
		os.exit(1)
	}

	vk_chk(vk.EnumeratePhysicalDevices(vkInstance, &deviceCount, raw_data(devices)))

	deviceProperties := vk.PhysicalDeviceProperties2 {
		sType = .PHYSICAL_DEVICE_PROPERTIES_2,
	}
	bestScore: i32 = -1
	bestDevice: vk.PhysicalDevice

	for d in devices {
		score: i32 = 0

		props: vk.PhysicalDeviceProperties
		vk.GetPhysicalDeviceProperties(d, &props)
		if props.deviceType == .DISCRETE_GPU {
			score += 1000_000_000
		}

		memProps: vk.PhysicalDeviceMemoryProperties
		vk.GetPhysicalDeviceMemoryProperties(d, &memProps)

		totalVRAM: vk.DeviceSize = 0
		for heap in memProps.memoryHeaps[:memProps.memoryHeapCount] {
			if .DEVICE_LOCAL in heap.flags {
				totalVRAM += heap.size
			}
		}
		score += i32(totalVRAM / (1024 * 1024))

		if score > bestScore {
			bestScore = score
			bestDevice = d
		}
	}

	if bestScore == -1 {
		fmt.eprintln("cannot find any device supporting our given Vulkan requirements")
		os.exit(1)
	}
	vkPhysicalDevice = bestDevice
	vk.GetPhysicalDeviceProperties2(vkPhysicalDevice, &deviceProperties)
	// fmt.printfln("Selected device: %s", deviceProperties.properties.deviceName)
	queueFamilyCount: u32 = 0
	vk.GetPhysicalDeviceQueueFamilyProperties(vkPhysicalDevice, &queueFamilyCount, nil)
	queueFamilies := make([]vk.QueueFamilyProperties, queueFamilyCount)

	vk.GetPhysicalDeviceQueueFamilyProperties(
		vkPhysicalDevice,
		&queueFamilyCount,
		raw_data(queueFamilies),
	)
	for queueFamily, i in queueFamilies {
		if (.GRAPHICS in queueFamily.queueFlags) {
			vkGraphicsQueueFamilyIndex = u32(i)
			break
		}
	}
	ensure(
		sdl.Vulkan_GetPresentationSupport(
			vkInstance,
			vkPhysicalDevice,
			vkGraphicsQueueFamilyIndex,
		),
	)
	// Logical device
	qfpriorities: f32 = 1.0
	queueCI := vk.DeviceQueueCreateInfo {
		sType            = .DEVICE_QUEUE_CREATE_INFO,
		queueFamilyIndex = vkGraphicsQueueFamilyIndex,
		queueCount       = 1,
		pQueuePriorities = &qfpriorities,
	}


	enabledVk12Features := vk.PhysicalDeviceVulkan12Features {
		sType                                     = .PHYSICAL_DEVICE_VULKAN_1_2_FEATURES,
		descriptorIndexing                        = true,
		shaderSampledImageArrayNonUniformIndexing = true,
		descriptorBindingVariableDescriptorCount  = true,
		runtimeDescriptorArray                    = true,
		bufferDeviceAddress                       = true,
	}
	enabledVk13Features := vk.PhysicalDeviceVulkan13Features {
		sType            = .PHYSICAL_DEVICE_VULKAN_1_3_FEATURES,
		pNext            = &enabledVk12Features,
		synchronization2 = true,
		dynamicRendering = true,
	}
	deviceExtensions := [?]cstring {
		vk.KHR_SWAPCHAIN_EXTENSION_NAME,
		vk.KHR_PUSH_DESCRIPTOR_EXTENSION_NAME,
	}
	enabledVk10Features := vk.PhysicalDeviceFeatures {
		samplerAnisotropy = true,
		shaderInt64       = true,
	}
	deviceCI := vk.DeviceCreateInfo {
		sType                   = .DEVICE_CREATE_INFO,
		pNext                   = &enabledVk13Features,
		queueCreateInfoCount    = 1,
		pQueueCreateInfos       = &queueCI,
		enabledExtensionCount   = u32(len(deviceExtensions)),
		ppEnabledExtensionNames = raw_data(deviceExtensions[:]),
		pEnabledFeatures        = &enabledVk10Features,
	}
	vk_chk(vk.CreateDevice(vkPhysicalDevice, &deviceCI, nil, &vkDevice))
	vk.GetDeviceQueue(vkDevice, vkGraphicsQueueFamilyIndex, 0, &vkQueue)
	vmaVulkanFunctions := vma.create_vulkan_functions()

	vk_chk(
		vma.create_allocator(
			{
				flags = {.Buffer_Device_Address},
				physical_device = vkPhysicalDevice,
				device = vkDevice,
				instance = vkInstance,
				vulkan_functions = &vmaVulkanFunctions,
			},
			&vkAllocator,
		),
	)


	ensure(sdl.Vulkan_CreateSurface(window, vkInstance, nil, &vkSurface))
	surfaceCaps: vk.SurfaceCapabilitiesKHR
	vk_chk(vk.GetPhysicalDeviceSurfaceCapabilitiesKHR(vkPhysicalDevice, vkSurface, &surfaceCaps))


	formatCount: u32 = 0
	vk_chk(vk.GetPhysicalDeviceSurfaceFormatsKHR(vkPhysicalDevice, vkSurface, &formatCount, nil))
	surfaceFormats := make([]vk.SurfaceFormatKHR, formatCount)
	vk_chk(
		vk.GetPhysicalDeviceSurfaceFormatsKHR(
			vkPhysicalDevice,
			vkSurface,
			&formatCount,
			raw_data(surfaceFormats),
		),
	)

	preferredFormat := surfaceFormats[0]
	for f in surfaceFormats {
		if (f.format == .A2B10G10R10_UNORM_PACK32 || f.format == .A2B10G10R10_SINT_PACK32) &&
		   f.colorSpace == .HDR10_ST2084_EXT {
			preferredFormat = f
			break
		}
		if f.format == .B10G11R11_UFLOAT_PACK32 || f.format == .R16G16B16A16_SFLOAT {
			preferredFormat = f
			break
		}
		if f.format == .B8G8R8A8_SRGB && f.colorSpace == .SRGB_NONLINEAR {
			preferredFormat = f
		}
	}

	swapchainImageFormat = preferredFormat.format
	swapchainColorSpace = preferredFormat.colorSpace
	ensure(swapchainImageFormat != .UNDEFINED)

	vk_chk(
		vk.CreateSwapchainKHR(
			vkDevice,
			&{
				sType = .SWAPCHAIN_CREATE_INFO_KHR,
				surface = vkSurface,
				minImageCount = surfaceCaps.minImageCount,
				imageFormat = swapchainImageFormat,
				imageColorSpace = preferredFormat.colorSpace,
				imageExtent = {
					width = surfaceCaps.currentExtent.width,
					height = surfaceCaps.currentExtent.height,
				},
				imageArrayLayers = 1,
				imageUsage = {.COLOR_ATTACHMENT},
				preTransform = {.IDENTITY},
				compositeAlpha = {.OPAQUE},
				presentMode = .FIFO,
			},
			nil,
			&vkSwapchain,
		),
	)
	vk.GetSwapchainImagesKHR(vkDevice, vkSwapchain, &vkImageCount, nil)
	vkSwapchainImages = make([]vk.Image, vkImageCount)
	vkSwpachainImageViews = make([]vk.ImageView, vkImageCount)
	vk.GetSwapchainImagesKHR(vkDevice, vkSwapchain, &vkImageCount, raw_data(vkSwapchainImages))

	for i in 0 ..< vkImageCount {
		vk_chk(
			vk.CreateImageView(
				vkDevice,
				&{
					sType = .IMAGE_VIEW_CREATE_INFO,
					image = vkSwapchainImages[i],
					viewType = .D2,
					format = swapchainImageFormat,
					subresourceRange = {aspectMask = {.COLOR}, levelCount = 1, layerCount = 1},
				},
				nil,
				&vkSwpachainImageViews[i],
			),
		)
	}

	depthFormatList := [?]vk.Format{.D32_SFLOAT, .D24_UNORM_S8_UINT}

	for format in depthFormatList {
		formatProperties := [?]vk.FormatProperties2{{sType = .FORMAT_PROPERTIES_2}}
		vk.GetPhysicalDeviceFormatProperties2(
			vkPhysicalDevice,
			format,
			raw_data(formatProperties[:]),
		)

		if .DEPTH_STENCIL_ATTACHMENT in
		   formatProperties[0].formatProperties.optimalTilingFeatures {
			depthFormat = format
			break
		}
	}

	ensure(depthFormat != .UNDEFINED)

	vk_chk(
		vma.create_image(
			vkAllocator,
			{
				sType = .IMAGE_CREATE_INFO,
				imageType = .D2,
				format = depthFormat,
				extent = {width = screenWidth, height = screenHeight, depth = 1},
				mipLevels = 1,
				arrayLayers = 1,
				samples = {._1},
				tiling = .OPTIMAL,
				usage = {.DEPTH_STENCIL_ATTACHMENT},
				initialLayout = .UNDEFINED,
			},
			{flags = {.Dedicated_Memory}, usage = .Auto},
			&vkDepthImage,
			&vmaDepthStencilAlloc,
			nil,
		),
	)

	vk_chk(
		vk.CreateImageView(
			vkDevice,
			&{
				sType = .IMAGE_VIEW_CREATE_INFO,
				image = vkDepthImage,
				viewType = .D2,
				format = depthFormat,
				subresourceRange = {
					aspectMask = vk.ImageAspectFlags{.DEPTH} if depthFormat == .D32_SFLOAT else vk.ImageAspectFlags{.DEPTH, .STENCIL},
					levelCount = 1,
					layerCount = 1,
				},
			},
			nil,
			&vkDepthImageView,
		),
	)


	for i in 0 ..< MAX_FRAMES_IN_FLIGHT {
		vk_chk(
			vma.create_buffer(
				vkAllocator,
				{
					sType = .BUFFER_CREATE_INFO,
					size = size_of(ShaderData),
					usage = {.UNIFORM_BUFFER, .SHADER_DEVICE_ADDRESS},
				},
				{
					flags = {
						.Host_Access_Sequential_Write,
						.Host_Access_Allow_Transfer_Instead,
						.Mapped,
					},
					usage = .Auto,
				},
				&shaderDataBuffers[i].buffer,
				&shaderDataBuffers[i].allocation,
				nil,
			),
		)
		vk_chk(
			vma.map_memory(
				vkAllocator,
				shaderDataBuffers[i].allocation,
				&shaderDataBuffers[i].mapped,
			),
		)
		addr_info := vk.BufferDeviceAddressInfo {
			sType  = .BUFFER_DEVICE_ADDRESS_INFO,
			buffer = shaderDataBuffers[i].buffer,
		}
		shaderDataBuffers[i].deviceAddress = vk.GetBufferDeviceAddress(vkDevice, &addr_info)


	}
	semaphoreCI := vk.SemaphoreCreateInfo {
		sType = .SEMAPHORE_CREATE_INFO,
	}
	for i in 0 ..< MAX_FRAMES_IN_FLIGHT {
		vk_chk(
			vk.CreateFence(
				vkDevice,
				&{sType = .FENCE_CREATE_INFO, flags = {.SIGNALED}},
				nil,
				&fences[i],
			),
		)
		vk_chk(vk.CreateSemaphore(vkDevice, &semaphoreCI, nil, &presentSemaphores[i]))

	}
	renderSemaphores = make([]vk.Semaphore, len(vkSwapchainImages))
	for &s in renderSemaphores {
		vk_chk(vk.CreateSemaphore(vkDevice, &semaphoreCI, nil, &s))
	}
	vk_chk(
		vk.CreateCommandPool(
			vkDevice,
			&{
				sType = .COMMAND_POOL_CREATE_INFO,
				flags = {.RESET_COMMAND_BUFFER},
				queueFamilyIndex = vkGraphicsQueueFamilyIndex,
			},
			nil,
			&vkCommandPool,
		),
	)

	vk_chk(
		vk.AllocateCommandBuffers(
			vkDevice,
			&{
				sType = .COMMAND_BUFFER_ALLOCATE_INFO,
				commandPool = vkCommandPool,
				commandBufferCount = MAX_FRAMES_IN_FLIGHT,
			},
			raw_data(drawCommandBuffers[:]),
		),
	)


}
pipeline_init :: proc() {


	ensure(os.exists(filepath.join({os.get_current_directory(), "assets", "suzanne.obj"})))
	objMesh, ok := obj.load_obj(filepath.join({"assets", "suzanne.obj"}, context.temp_allocator))
	ensure(ok)


	vk_chk(
		vma.create_buffer(
			vkAllocator,
			{
				sType = .BUFFER_CREATE_INFO,
				size = vk.DeviceSize(
					size_of(obj.Vertex) * len(objMesh.vertices) +
					size_of(u32) * len(objMesh.indices),
				),
				usage = {.VERTEX_BUFFER, .INDEX_BUFFER},
			},
			{
				flags = {.Host_Access_Sequential_Write, .Host_Access_Allow_Transfer_Instead},
				usage = .Auto,
			},
			&vBuffer,
			&vBufferAllocation,
			nil,
		),
	)
	bufferPtr: rawptr
	vertexBufferSize = size_of(obj.Vertex) * len(objMesh.vertices)

	vk_chk(vma.map_memory(vkAllocator, vBufferAllocation, &bufferPtr))
	mem.copy(bufferPtr, raw_data(objMesh.vertices), size_of(obj.Vertex) * len(objMesh.vertices))


	indicesCount = u32(len(objMesh.indices))
	mem.copy(
		rawptr(uintptr(bufferPtr) + uintptr(vertexBufferSize)),
		raw_data(objMesh.indices),
		size_of(u32) * len(objMesh.indices),
	)
	vma.unmap_memory(vkAllocator, vBufferAllocation)


	for &texture, i in textures {
		width, height, channels: i32
		pixels := image.load(
			strings.clone_to_cstring(
				filepath.join({"assets", fmt.tprintf("suzanne%d.png", i)}),
				context.temp_allocator,
			),
			&width,
			&height,
			&channels,
			4,
		)
		imageFormat: vk.Format = .B8G8R8A8_SRGB

		ensure(pixels != nil)
		vk_chk(
			vma.create_image(
				vkAllocator,
				{
					sType = .IMAGE_CREATE_INFO,
					imageType = .D2,
					format = imageFormat,
					extent = {width = u32(width), height = u32(height), depth = 1},
					mipLevels = 1,
					arrayLayers = 1,
					samples = {._1},
					tiling = .OPTIMAL,
					usage = {.TRANSFER_DST, .SAMPLED},
					initialLayout = .UNDEFINED,
				},
				{usage = .Auto},
				&texture.image,
				&texture.allocation,
				nil,
			),
		)

		imgSrcBuffer: vk.Buffer
		imgSrcAllocation: vma.Allocation
		vk_chk(
			vma.create_buffer(
				vkAllocator,
				{
					sType = .BUFFER_CREATE_INFO,
					size = vk.DeviceSize(width * height * 4),
					usage = {.TRANSFER_SRC},
				},
				{flags = {.Host_Access_Sequential_Write, .Mapped}, usage = .Auto},
				&imgSrcBuffer,
				&imgSrcAllocation,
				nil,
			),
		)
		imgSrcBufferPtr: rawptr
		vk_chk(vma.map_memory(vkAllocator, imgSrcAllocation, &imgSrcBufferPtr))
		mem.copy(imgSrcBufferPtr, pixels, int(width) * int(height) * 4)

		fenceOneTime: vk.Fence
		vk_chk(vk.CreateFence(vkDevice, &{sType = .FENCE_CREATE_INFO}, nil, &fenceOneTime))


		cbOneTime: vk.CommandBuffer
		vk_chk(
			vk.AllocateCommandBuffers(
				vkDevice,
				&vk.CommandBufferAllocateInfo {
					sType = .COMMAND_BUFFER_ALLOCATE_INFO,
					commandPool = vkCommandPool,
					commandBufferCount = 1,
				},
				&cbOneTime,
			),
		)
		vk_chk(
			vk.BeginCommandBuffer(
				cbOneTime,
				&vk.CommandBufferBeginInfo {
					sType = .COMMAND_BUFFER_BEGIN_INFO,
					flags = {.ONE_TIME_SUBMIT},
				},
			),
		)

		barrier := vk.ImageMemoryBarrier2 {
			sType = .IMAGE_MEMORY_BARRIER_2,
			srcStageMask = {},
			srcAccessMask = {},
			dstStageMask = {.TRANSFER},
			dstAccessMask = {.TRANSFER_WRITE},
			oldLayout = .UNDEFINED,
			newLayout = .TRANSFER_DST_OPTIMAL,
			image = texture.image,
			subresourceRange = {aspectMask = {.COLOR}, levelCount = 1, layerCount = 1},
		}
		vk.CmdPipelineBarrier2(
			cbOneTime,
			&vk.DependencyInfo {
				sType = .DEPENDENCY_INFO,
				imageMemoryBarrierCount = 1,
				pImageMemoryBarriers = &barrier,
			},
		)

		copyRegion := vk.BufferImageCopy {
			bufferOffset = 0,
			imageSubresource = {aspectMask = {.COLOR}, mipLevel = 0, layerCount = 1},
			imageExtent = {width = u32(width), height = u32(height), depth = 1},
		}
		vk.CmdCopyBufferToImage(
			cbOneTime,
			imgSrcBuffer,
			texture.image,
			.TRANSFER_DST_OPTIMAL,
			1,
			&copyRegion,
		)

		barrier = vk.ImageMemoryBarrier2 {
			sType = .IMAGE_MEMORY_BARRIER_2,
			srcStageMask = {.TRANSFER},
			srcAccessMask = {.TRANSFER_WRITE},
			dstStageMask = {.FRAGMENT_SHADER},
			dstAccessMask = {.SHADER_READ},
			oldLayout = .TRANSFER_DST_OPTIMAL,
			newLayout = .READ_ONLY_OPTIMAL,
			image = texture.image,
			subresourceRange = {aspectMask = {.COLOR}, levelCount = 1, layerCount = 1},
		}
		vk.CmdPipelineBarrier2(
			cbOneTime,
			&vk.DependencyInfo {
				sType = .DEPENDENCY_INFO,
				imageMemoryBarrierCount = 1,
				pImageMemoryBarriers = &barrier,
			},
		)

		vk_chk(vk.EndCommandBuffer(cbOneTime))
		vk_chk(
			vk.QueueSubmit(
				vkQueue,
				1,
				&vk.SubmitInfo {
					sType = .SUBMIT_INFO,
					commandBufferCount = 1,
					pCommandBuffers = &cbOneTime,
				},
				fenceOneTime,
			),
		)
		vk_chk(vk.WaitForFences(vkDevice, 1, &fenceOneTime, true, max(u64)))

		vk.FreeCommandBuffers(vkDevice, vkCommandPool, 1, &cbOneTime)
		vma.unmap_memory(vkAllocator, imgSrcAllocation)
		vma.destroy_buffer(vkAllocator, imgSrcBuffer, imgSrcAllocation)


		vk.DestroyFence(vkDevice, fenceOneTime, nil)

		vk_chk(
			vk.CreateImageView(
				vkDevice,
				&vk.ImageViewCreateInfo {
					sType = .IMAGE_VIEW_CREATE_INFO,
					image = texture.image,
					viewType = .D2,
					format = imageFormat,
					subresourceRange = {
						aspectMask = {.COLOR},
						baseMipLevel = 0,
						levelCount = 1,
						baseArrayLayer = 0,
						layerCount = 1,
					},
				},
				nil,
				&texture.view,
			),
		)

		vk_chk(
			vk.CreateSampler(
				vkDevice,
				&vk.SamplerCreateInfo {
					sType = .SAMPLER_CREATE_INFO,
					magFilter = .LINEAR,
					minFilter = .LINEAR,
					mipmapMode = .LINEAR,
					anisotropyEnable = true,
					maxAnisotropy = 8.0,
					maxLod = 1.0,
				},
				nil,
				&texture.sampler,
			),
		)

		textureDescriptors[i] = {
			sampler     = texture.sampler,
			imageView   = texture.view,
			imageLayout = .READ_ONLY_OPTIMAL,
		}

	}

	descLayoutBindings := [?]vk.DescriptorSetLayoutBinding {
		{
			binding = 0,
			descriptorType = .COMBINED_IMAGE_SAMPLER,
			descriptorCount = MAX_TEXTURES,
			stageFlags = {.FRAGMENT},
		},
	}

	vk_chk(
		vk.CreateDescriptorSetLayout(
			vkDevice,
			&vk.DescriptorSetLayoutCreateInfo {
				sType = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
				flags = {.PUSH_DESCRIPTOR_KHR},
				bindingCount = len(descLayoutBindings),
				pBindings = raw_data(descLayoutBindings[:]),
			},
			nil,
			&descriptorSetLayoutTex,
		),
	)

	VERT_CODE :: #load("../build/shaders/vert.spv")
	FRAG_CODE :: #load("../build/shaders/frag.spv")

	vertModule := create_shader_module(vkDevice, VERT_CODE)
	fragModule := create_shader_module(vkDevice, FRAG_CODE)

	vk_chk(
		vk.CreatePipelineLayout(
			vkDevice,
			&{
				sType = .PIPELINE_LAYOUT_CREATE_INFO,
				setLayoutCount = 1,
				pSetLayouts = &descriptorSetLayoutTex,
				pushConstantRangeCount = 1,
				pPushConstantRanges = &vk.PushConstantRange {
					stageFlags = {.VERTEX},
					size = size_of(vk.DeviceAddress),
				},
			},
			nil,
			&pipelineLayout,
		),
	)
	vaDescriptors := [?]vk.VertexInputAttributeDescription {
		{location = 0, binding = 0, format = .R32G32B32_SFLOAT},
		{
			location = 1,
			binding = 0,
			format = .R32G32B32_SFLOAT,
			offset = u32(offset_of(obj.Vertex, norm)),
		},
		{
			location = 2,
			binding = 0,
			format = .R32G32_SFLOAT,
			offset = u32(offset_of(obj.Vertex, uv)),
		},
	}

	dynamicStates := [?]vk.DynamicState{.VIEWPORT, .SCISSOR}
	pipelineStages := [?]vk.PipelineShaderStageCreateInfo {
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
	vk_chk(
		vk.CreateGraphicsPipelines(
			vkDevice,
			{},
			1,
			&vk.GraphicsPipelineCreateInfo {
				sType = .GRAPHICS_PIPELINE_CREATE_INFO,
				pNext = &vk.PipelineRenderingCreateInfo {
					sType = .PIPELINE_RENDERING_CREATE_INFO,
					colorAttachmentCount = 1,
					pColorAttachmentFormats = &swapchainImageFormat,
					depthAttachmentFormat = depthFormat,
				},
				stageCount = len(pipelineStages),
				pStages = raw_data(pipelineStages[:]),
				pVertexInputState = &vk.PipelineVertexInputStateCreateInfo {
					sType = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
					vertexBindingDescriptionCount = 1,
					pVertexBindingDescriptions = &vk.VertexInputBindingDescription {
						binding = 0,
						stride = size_of(obj.Vertex),
						inputRate = .VERTEX,
					},
					vertexAttributeDescriptionCount = len(vaDescriptors),
					pVertexAttributeDescriptions = raw_data(vaDescriptors[:]),
				},
				pInputAssemblyState = &vk.PipelineInputAssemblyStateCreateInfo {
					sType = .PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
					topology = .TRIANGLE_LIST,
				},
				pViewportState = &vk.PipelineViewportStateCreateInfo {
					sType = .PIPELINE_VIEWPORT_STATE_CREATE_INFO,
					viewportCount = 1,
					scissorCount = 1,
				},
				pRasterizationState = &vk.PipelineRasterizationStateCreateInfo {
					sType = .PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
					lineWidth = 1.0,
				},
				pMultisampleState = &vk.PipelineMultisampleStateCreateInfo {
					sType = .PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
					rasterizationSamples = {._1},
				},
				pDepthStencilState = &vk.PipelineDepthStencilStateCreateInfo {
					sType = .PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
					depthTestEnable = true,
					depthWriteEnable = true,
					depthCompareOp = .LESS_OR_EQUAL,
				},
				pColorBlendState = &vk.PipelineColorBlendStateCreateInfo {
					sType = .PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
					attachmentCount = 1,
					pAttachments = &vk.PipelineColorBlendAttachmentState {
						colorWriteMask = {.R, .G, .B, .A},
					},
				},
				pDynamicState = &vk.PipelineDynamicStateCreateInfo {
					sType = .PIPELINE_DYNAMIC_STATE_CREATE_INFO,
					dynamicStateCount = len(dynamicStates),
					pDynamicStates = raw_data(dynamicStates[:]),
				},
				layout = pipelineLayout,
			},
			nil,
			&graphicsPipeline,
		),
	)
	vk.DestroyShaderModule(vkDevice, vertModule, nil)
	vk.DestroyShaderModule(vkDevice, fragModule, nil)
}
sdl_ensure :: proc(cond: bool, message: string = "") {
	msg := fmt.tprintf("%s:%s\n", message, sdl.GetError())
	ensure(cond, msg)
}
vk_chk :: proc(r: vk.Result) {
	if r != .SUCCESS {
		when ODIN_DEBUG {
			log.fatalf("[VULKAN RETURN ERROR]: %s", fmt.enum_value_to_string(r))
		} else {
			fmt.eprintf("[VULKAN RETURN ERROR]: %s", fmt.enum_value_to_string(r))
		}
	}
}
vulkan_render :: proc(c: ^Camera) {
	vk_chk(vk.WaitForFences(vkDevice, 1, &fences[frameIndex], true, max(u64)))
	vk_chk(vk.ResetFences(vkDevice, 1, &fences[frameIndex]))
	vk_chk_swapchain(
		vk.AcquireNextImageKHR(
			vkDevice,
			vkSwapchain,
			max(u64),
			presentSemaphores[frameIndex],
			vk.Fence{},
			&imageIndex,
		),
	)
	view, proj := Camera_view_proj(c)
	shaderData: ShaderData = {
		projection = proj,
		view       = view,
	}
	shaderData.projection[1][1] *= -1
	for &model, i in shaderData.model {
		model =
			la.matrix4_translate_f32([3]f32{f32(i * 3), 0, 0}) *
			la.identity_matrix(matrix[4, 4]f32)
	}

	mem.copy(shaderDataBuffers[frameIndex].mapped, &shaderData, size_of(shaderData))


	cb := drawCommandBuffers[frameIndex]
	vk_chk(vk.ResetCommandBuffer(cb, {}))

	vk_chk(
		vk.BeginCommandBuffer(
			cb,
			&{sType = .COMMAND_BUFFER_BEGIN_INFO, flags = {.ONE_TIME_SUBMIT}},
		),
	)
	barriers := [?]vk.ImageMemoryBarrier2 {
		{
			sType = .IMAGE_MEMORY_BARRIER_2,
			srcStageMask = {.COLOR_ATTACHMENT_OUTPUT},
			srcAccessMask = {},
			dstStageMask = {.COLOR_ATTACHMENT_OUTPUT},
			dstAccessMask = {.COLOR_ATTACHMENT_READ, .COLOR_ATTACHMENT_WRITE},
			oldLayout = .UNDEFINED,
			newLayout = .ATTACHMENT_OPTIMAL,
			image = vkSwapchainImages[imageIndex],
			subresourceRange = {aspectMask = {.COLOR}, levelCount = 1, layerCount = 1},
		},
		{
			sType = .IMAGE_MEMORY_BARRIER_2,
			srcStageMask = {.EARLY_FRAGMENT_TESTS, .LATE_FRAGMENT_TESTS},
			srcAccessMask = {.DEPTH_STENCIL_ATTACHMENT_WRITE},
			dstStageMask = {.EARLY_FRAGMENT_TESTS, .LATE_FRAGMENT_TESTS},
			dstAccessMask = {.DEPTH_STENCIL_ATTACHMENT_WRITE},
			oldLayout = .UNDEFINED,
			newLayout = .ATTACHMENT_OPTIMAL,
			image = vkDepthImage,
			subresourceRange = {aspectMask = {.DEPTH}, levelCount = 1, layerCount = 1},
		},
	}
	vk.CmdPipelineBarrier2(
		cb,
		&{
			sType = .DEPENDENCY_INFO,
			imageMemoryBarrierCount = len(barriers),
			pImageMemoryBarriers = raw_data(barriers[:]),
		},
	)
	vk.CmdBeginRendering(
		cb,
		&{
			sType = .RENDERING_INFO,
			renderArea = {extent = {width = screenWidth, height = screenHeight}},
			layerCount = 1,
			colorAttachmentCount = 1,
			pColorAttachments = &vk.RenderingAttachmentInfo {
				sType = .RENDERING_ATTACHMENT_INFO,
				imageView = vkSwpachainImageViews[imageIndex],
				imageLayout = .ATTACHMENT_OPTIMAL,
				loadOp = .CLEAR,
				storeOp = .STORE,
				clearValue = {color = {float32 = {0.2, 0.4, 0.6, 1}}},
			},
			pDepthAttachment = &vk.RenderingAttachmentInfo {
				sType = .RENDERING_ATTACHMENT_INFO,
				imageView = vkDepthImageView,
				imageLayout = .ATTACHMENT_OPTIMAL,
				loadOp = .CLEAR,
				storeOp = .DONT_CARE,
				clearValue = {depthStencil = {1, 0}},
			},
		},
	)

	vk.CmdSetViewport(
		cb,
		0,
		1,
		&vk.Viewport {
			width = f32(screenWidth),
			height = f32(screenHeight),
			minDepth = 0,
			maxDepth = 1,
		},
	)
	vk.CmdSetScissor(cb, 0, 1, &vk.Rect2D{extent = {width = screenWidth, height = screenHeight}})

	vk.CmdBindPipeline(cb, .GRAPHICS, graphicsPipeline)
	assert(len(textures) < MAX_TEXTURES)
	allDescriptors: [MAX_TEXTURES]vk.DescriptorImageInfo
	for i in 0 ..< MAX_TEXTURES {
		allDescriptors[i] = textureDescriptors[i % len(textures)]
	}

	setsToWrite := [?]vk.WriteDescriptorSet {
		{
			sType = .WRITE_DESCRIPTOR_SET,
			dstBinding = 0,
			dstArrayElement = 0,
			descriptorCount = MAX_TEXTURES,
			descriptorType = .COMBINED_IMAGE_SAMPLER,
			pImageInfo = raw_data(allDescriptors[:]),
		},
	}
	vk.CmdPushDescriptorSetKHR(
		cb,
		.GRAPHICS,
		pipelineLayout,
		0,
		len(setsToWrite),
		raw_data(setsToWrite[:]),
	)


	vk.CmdPushConstants(
		cb,
		pipelineLayout,
		{.VERTEX},
		0,
		size_of(vk.DeviceAddress),
		&shaderDataBuffers[frameIndex].deviceAddress,
	)
	vOffset := vk.DeviceSize(0)
	vk.CmdBindVertexBuffers(cb, 0, 1, &vBuffer, &vOffset)

	assert(vertexBufferSize != 0)
	vk.CmdBindIndexBuffer(cb, vBuffer, vk.DeviceSize(vertexBufferSize), .UINT32)

	// vk.CmdPushConstants(
	// 	cb,
	// 	pipelineLayout,
	// 	{.VERTEX},
	// 	0,
	// 	size_of(vk.DeviceAddress),
	// 	&shaderDataBuffers[frameIndex].deviceAddress,
	// )
	assert(indicesCount != 0)
	vk.CmdDrawIndexed(cb, indicesCount, 3, 0, 0, 0)
	vk.CmdEndRendering(cb)

	vk.CmdPipelineBarrier2(
		cb,
		&{
			sType = .DEPENDENCY_INFO,
			imageMemoryBarrierCount = 1,
			pImageMemoryBarriers = &vk.ImageMemoryBarrier2 {
				sType = .IMAGE_MEMORY_BARRIER_2,
				srcStageMask = {.COLOR_ATTACHMENT_OUTPUT},
				srcAccessMask = {.COLOR_ATTACHMENT_WRITE},
				dstStageMask = {.COLOR_ATTACHMENT_OUTPUT},
				dstAccessMask = {},
				oldLayout = .COLOR_ATTACHMENT_OPTIMAL,
				newLayout = .PRESENT_SRC_KHR,
				image = vkSwapchainImages[imageIndex],
				subresourceRange = {aspectMask = {.COLOR}, levelCount = 1, layerCount = 1},
			},
		},
	)
	vk.EndCommandBuffer(cb)
	waitStage: vk.PipelineStageFlags = {.COLOR_ATTACHMENT_OUTPUT}
	vk_chk(
		vk.QueueSubmit(
			vkQueue,
			1,
			&vk.SubmitInfo {
				sType = .SUBMIT_INFO,
				waitSemaphoreCount = 1,
				pWaitSemaphores = &presentSemaphores[frameIndex],
				pWaitDstStageMask = &waitStage,
				commandBufferCount = 1,
				pCommandBuffers = &cb,
				signalSemaphoreCount = 1,
				pSignalSemaphores = &renderSemaphores[imageIndex],
			},
			fences[frameIndex],
		),
	)
	frameIndex = (frameIndex + 1) % MAX_FRAMES_IN_FLIGHT
	vk_chk_swapchain(
		vk.QueuePresentKHR(
			vkQueue,
			&{
				sType = .PRESENT_INFO_KHR,
				waitSemaphoreCount = 1,
				pWaitSemaphores = &renderSemaphores[imageIndex],
				swapchainCount = 1,
				pSwapchains = &vkSwapchain,
				pImageIndices = &imageIndex,
			},
		),
	)


}
vulkan_update_swapchain :: proc() {
	if updateSwapchain == false do return
	vk_chk(vk.DeviceWaitIdle(vkDevice))

	surfaceCaps: vk.SurfaceCapabilitiesKHR
	vk_chk(vk.GetPhysicalDeviceSurfaceCapabilitiesKHR(vkPhysicalDevice, vkSurface, &surfaceCaps))

	oldSwapchain := vkSwapchain

	swapchainCI := vk.SwapchainCreateInfoKHR {
		sType = .SWAPCHAIN_CREATE_INFO_KHR,
		surface = vkSurface,
		minImageCount = surfaceCaps.minImageCount,
		imageFormat = swapchainImageFormat,
		imageColorSpace = swapchainColorSpace,
		imageExtent = {width = screenWidth, height = screenHeight},
		imageArrayLayers = 1,
		imageUsage = {.COLOR_ATTACHMENT},
		preTransform = {.IDENTITY},
		compositeAlpha = {.OPAQUE},
		presentMode = .FIFO,
		oldSwapchain = oldSwapchain,
	}

	vk_chk(vk.CreateSwapchainKHR(vkDevice, &swapchainCI, nil, &vkSwapchain))

	for view in vkSwpachainImageViews {
		vk.DestroyImageView(vkDevice, view, nil)
	}

	vk_chk(vk.GetSwapchainImagesKHR(vkDevice, vkSwapchain, &vkImageCount, nil))
	vkSwapchainImages = make([]vk.Image, vkImageCount)
	vkSwpachainImageViews = make([]vk.ImageView, vkImageCount)
	vk_chk(
		vk.GetSwapchainImagesKHR(
			vkDevice,
			vkSwapchain,
			&vkImageCount,
			raw_data(vkSwapchainImages),
		),
	)

	for i in 0 ..< vkImageCount {
		viewCI := vk.ImageViewCreateInfo {
			sType = .IMAGE_VIEW_CREATE_INFO,
			image = vkSwapchainImages[i],
			viewType = .D2,
			format = swapchainImageFormat,
			subresourceRange = {aspectMask = {.COLOR}, levelCount = 1, layerCount = 1},
		}

		vk_chk(vk.CreateImageView(vkDevice, &viewCI, nil, &vkSwpachainImageViews[i]))
	}

	vk.DestroySwapchainKHR(vkDevice, oldSwapchain, nil)

	vk.DestroyImageView(vkDevice, vkDepthImageView, nil)
	vma.destroy_image(vkAllocator, vkDepthImage, vmaDepthStencilAlloc)

	depthImageCI := vk.ImageCreateInfo {
		sType = .IMAGE_CREATE_INFO,
		imageType = .D2,
		format = depthFormat,
		extent = {width = screenWidth, height = screenHeight, depth = 1},
		mipLevels = 1,
		arrayLayers = 1,
		samples = {._1},
		tiling = .OPTIMAL,
		usage = {.DEPTH_STENCIL_ATTACHMENT},
	}

	allocCI := vma.Allocation_Create_Info {
		flags = {.Dedicated_Memory},
		usage = .Auto,
	}

	vk_chk(
		vma.create_image(
			vkAllocator,
			depthImageCI,
			allocCI,
			&vkDepthImage,
			&vmaDepthStencilAlloc,
			nil,
		),
	)

	depthViewCI := vk.ImageViewCreateInfo {
		sType = .IMAGE_VIEW_CREATE_INFO,
		image = vkDepthImage,
		viewType = .D2,
		format = depthFormat,
		subresourceRange = {aspectMask = {.DEPTH}, levelCount = 1, layerCount = 1},
	}

	vk_chk(vk.CreateImageView(vkDevice, &depthViewCI, nil, &vkDepthImageView))
}
vk_chk_swapchain :: proc(r: vk.Result) {
	if r != .SUCCESS {
		if r == .ERROR_OUT_OF_DATE_KHR {
			updateSwapchain = true
		} else {
			vk_chk(r)
		}
	}
}
vulkan_cleanup :: proc() {
	vk.DeviceWaitIdle(vkDevice)

	for i in 0 ..< MAX_FRAMES_IN_FLIGHT {
		if fences[i] != {} do vk.DestroyFence(vkDevice, fences[i], nil)

		if presentSemaphores[i] != {} do vk.DestroySemaphore(vkDevice, presentSemaphores[i], nil)

		if shaderDataBuffers[i].buffer != {} {
			vma.unmap_memory(vkAllocator, shaderDataBuffers[i].allocation)
			vma.destroy_buffer(
				vkAllocator,
				shaderDataBuffers[i].buffer,
				shaderDataBuffers[i].allocation,
			)
		}

	}

	for s in renderSemaphores {
		if s != {} do vk.DestroySemaphore(vkDevice, s, nil)
	}

	if vkDepthImageView != {} do vk.DestroyImageView(vkDevice, vkDepthImageView, nil)

	if vkDepthImage != {} do vma.destroy_image(vkAllocator, vkDepthImage, vmaDepthStencilAlloc)


	for view in vkSwpachainImageViews {
		if view != {} do vk.DestroyImageView(vkDevice, view, nil)
	}

	if vBuffer != {} do vma.destroy_buffer(vkAllocator, vBuffer, vBufferAllocation)


	for t in textures {
		if t.view != {} do vk.DestroyImageView(vkDevice, t.view, nil)

		if t.sampler != {} do vk.DestroySampler(vkDevice, t.sampler, nil)

		if t.image != {} do vma.destroy_image(vkAllocator, t.image, t.allocation)

	}

	if descriptorSetLayoutTex != {} do vk.DestroyDescriptorSetLayout(vkDevice, descriptorSetLayoutTex, nil)


	if pipelineLayout != {} do vk.DestroyPipelineLayout(vkDevice, pipelineLayout, nil)

	if graphicsPipeline != {} do vk.DestroyPipeline(vkDevice, graphicsPipeline, nil)


	if vkSwapchain != {} do vk.DestroySwapchainKHR(vkDevice, vkSwapchain, nil)

	if vkCommandPool != {} do vk.DestroyCommandPool(vkDevice, vkCommandPool, nil)


	if vkAllocator != nil do vma.destroy_allocator(vkAllocator)


	if vkSurface != {} do vk.DestroySurfaceKHR(vkInstance, vkSurface, nil)

	if vkDevice != {} do vk.DestroyDevice(vkDevice, nil)

	if vkInstance != {} do vk.DestroyInstance(vkInstance, nil)

}
