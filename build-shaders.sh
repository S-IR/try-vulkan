mkdir build;
mkdir build/shaders;
glslangValidator -G --target-env vulkan1.3 -S frag -DFRAGMENT -o build/shaders/frag.spv src/glsl/shader.glsl;
glslangValidator -G --target-env vulkan1.3 -S vert -DVERTEX -o build/shaders/vert.spv src/glsl/shader.glsl
