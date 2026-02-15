package main
import "core:fmt"
import la "core:math/linalg"
import "core:mem"
import vk "vendor:vulkan"
PipelineData :: struct {
	descriptorSetLayout: vk.DescriptorSetLayout,
	layout:              vk.PipelineLayout,
	graphicsPipeline:    vk.Pipeline,
}

model_pipeline_init :: proc() -> (modelPipeline: PipelineData) {
	descLayoutBindings := [?]vk.DescriptorSetLayoutBinding {
		{
			binding = 0,
			descriptorType = .COMBINED_IMAGE_SAMPLER,
			descriptorCount = MAX_TEXTURES,
			stageFlags = {.FRAGMENT},
		},
		{
			binding = 1,
			descriptorType = .UNIFORM_BUFFER,
			descriptorCount = 1,
			stageFlags = {.VERTEX, .FRAGMENT},
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
			&modelPipeline.descriptorSetLayout,
		),
	)

	VERT_SPV :: #load("../build/shader-binaries/model.vertex.spv")
	FRAG_SPV :: #load("../build/shader-binaries/model.fragment.spv")

	vertModule := create_shader_module(vkDevice, VERT_SPV)
	fragModule := create_shader_module(vkDevice, FRAG_SPV)
	vk_chk(
		vk.CreatePipelineLayout(
			vkDevice,
			&{
				sType = .PIPELINE_LAYOUT_CREATE_INFO,
				setLayoutCount = 1,
				pSetLayouts = &modelPipeline.descriptorSetLayout,
				pushConstantRangeCount = 1,
				pPushConstantRanges = &vk.PushConstantRange {
					stageFlags = {.VERTEX},
					offset = 0,
					size = size_of(la.Matrix4f32),
				},
			},
			nil,
			&modelPipeline.layout,
		),
	)

	viBindings := [?]vk.VertexInputBindingDescription {
		{binding = 0, stride = size_of([3]f32), inputRate = .VERTEX},
		{binding = 1, stride = size_of([3]f32), inputRate = .VERTEX},
		{binding = 2, stride = size_of([2]f32), inputRate = .VERTEX},
	}

	vaDescriptors := [?]vk.VertexInputAttributeDescription {
		{location = 0, binding = 0, format = .R32G32B32_SFLOAT, offset = 0},
		{location = 1, binding = 1, format = .R32G32B32_SFLOAT, offset = 0},
		{location = 2, binding = 2, format = .R32G32_SFLOAT, offset = 0},
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
					vertexBindingDescriptionCount = len(viBindings),
					pVertexBindingDescriptions = raw_data(viBindings[:]),
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
				layout = modelPipeline.layout,
			},
			nil,
			&modelPipeline.graphicsPipeline,
		),
	)
	vk.DestroyShaderModule(vkDevice, vertModule, nil)
	vk.DestroyShaderModule(vkDevice, fragModule, nil)
	return modelPipeline
}
model_pipeline_destroy :: proc(p: PipelineData) {
	if p.descriptorSetLayout != {} do vk.DestroyDescriptorSetLayout(vkDevice, p.descriptorSetLayout, nil)
	if p.layout != {} do vk.DestroyPipelineLayout(vkDevice, p.layout, nil)
	if p.graphicsPipeline != {} do vk.DestroyPipeline(vkDevice, p.graphicsPipeline, nil)

}

model_draw :: proc(cb: vk.CommandBuffer, c: ^Camera, model: Model, pipeline: PipelineData) {

	vk.CmdBindPipeline(cb, .GRAPHICS, pipeline.graphicsPipeline)

	view, proj := Camera_view_proj(c)
	shaderData := ShaderData {
		projection = proj,
		view       = view,
		lightPos   = {0, 0, 0, 1},
	}
	shaderData.projection[1][1] *= -1
	mem.copy(shaderDataBuffers[frameIndex].mapped, &shaderData, size_of(shaderData))


	uboInfo := vk.DescriptorBufferInfo {
		buffer = shaderDataBuffers[frameIndex].buffer,
		offset = 0,
		range  = size_of(ShaderData),
	}

	allDescriptors: [MAX_TEXTURES]vk.DescriptorImageInfo

	for &obj in model.renderObjs {
		for j in 0 ..< MAX_TEXTURES {
			allDescriptors[j] = obj.material.baseColorTexture.descriptor
		}
		modelMatrix := obj.primitive.transform * la.MATRIX4F32_IDENTITY
		vk.CmdPushConstants(
			cb,
			pipeline.layout,
			{.VERTEX},
			0,
			size_of(la.Matrix4f32),
			&modelMatrix,
		)

		for j in 0 ..< MAX_TEXTURES {
			allDescriptors[j] = obj.material.baseColorTexture.descriptor
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
			{
				sType = .WRITE_DESCRIPTOR_SET,
				dstBinding = 1,
				dstArrayElement = 0,
				descriptorCount = 1,
				descriptorType = .UNIFORM_BUFFER,
				pBufferInfo = &uboInfo,
			},
		}

		vk.CmdPushDescriptorSetKHR(
			cb,
			.GRAPHICS,
			pipeline.layout,
			0,
			len(setsToWrite),
			raw_data(setsToWrite[:]),
		)

		buffers := [3]vk.Buffer {
			obj.primitive.posBuffer,
			obj.primitive.normBuffer,
			obj.primitive.uvBuffer,
		}
		offsets := [3]vk.DeviceSize{0, 0, 0}
		vk.CmdBindVertexBuffers(cb, 0, 3, raw_data(buffers[:]), raw_data(offsets[:]))
		vk.CmdBindIndexBuffer(cb, obj.primitive.indexBuffer, 0, .UINT32)

		assert(obj.primitive.indexCount != 0)
		vk.CmdDrawIndexed(cb, obj.primitive.indexCount, 1, 0, 0, 0)
	}


}
