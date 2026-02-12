package main
import vk "vendor:vulkan"
create_shader_module :: proc(device: vk.Device, code: []byte) -> vk.ShaderModule {
	assert(len(code) % 4 == 0, "SPIR-V bytecode size must be multiple of 4 bytes")

	code_u32 := transmute([]u32)code

	ci := vk.ShaderModuleCreateInfo {
		sType    = .SHADER_MODULE_CREATE_INFO,
		codeSize = len(code),
		pCode    = raw_data(code_u32),
	}

	shader_module: vk.ShaderModule
	res := vk.CreateShaderModule(device, &ci, nil, &shader_module)
	vk_chk(res)

	return shader_module
}
