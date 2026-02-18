// src/demucs_v4_trt.cpp
// Compiles to: demucs_v4_trt.dll
// Purpose: Flattens TensorRT C++ classes into a simple C API for C# P/Invoke
// Build via: scripts/build_bridge.ps1

#include <iostream>
#include <vector>
#include <memory>
#include <cstring>
#include <NvInfer.h>
#include <cuda_runtime_api.h>

// Pragmas intentionally omitted - build script links nvinfer_10.lib and cudart.lib directly.

using namespace nvinfer1;

class Logger : public ILogger {
    void log(Severity severity, const char* msg) noexcept override {
        // Only surface warnings and errors - suppress the TRT startup noise
        if (severity <= Severity::kWARNING)
            std::cout << "[TRT] " << msg << std::endl;
    }
} gLogger;

struct TrtContext {
    std::unique_ptr<IRuntime>          runtime;
    std::unique_ptr<ICudaEngine>       engine;
    std::unique_ptr<IExecutionContext> context;
    void*        d_input    = nullptr;
    void*        d_output   = nullptr;
    cudaStream_t stream     = nullptr;
    int          chunkLen   = 0;
    int          numSources = 0;
};

extern "C" __declspec(dllexport)
void* Trt_Init(const char* modelPath, int* chunkLen, int* numSources)
{
    auto* ctx = new TrtContext();

    // 1. Runtime
    ctx->runtime.reset(createInferRuntime(gLogger));
    if (!ctx->runtime) { delete ctx; return nullptr; }

    // 2. Load .trt file
    FILE* f = fopen(modelPath, "rb");
    if (!f) {
        std::cout << "[TRT] ERROR: Could not open model file: " << modelPath << std::endl;
        delete ctx; return nullptr;
    }
    fseek(f, 0, SEEK_END);
    long size = ftell(f);
    fseek(f, 0, SEEK_SET);
    std::vector<char> modelData(size);
    fread(modelData.data(), 1, size, f);
    fclose(f);

    // 3. Deserialize engine
    ctx->engine.reset(ctx->runtime->deserializeCudaEngine(modelData.data(), size));
    if (!ctx->engine) {
        std::cout << "[TRT] ERROR: Failed to deserialize engine. Wrong TRT version?" << std::endl;
        delete ctx; return nullptr;
    }

    // 4. Execution context
    ctx->context.reset(ctx->engine->createExecutionContext());
    if (!ctx->context) { delete ctx; return nullptr; }

    // 5. Read tensor shapes
    // Input:  [1, 2, chunkLen]
    // Output: [1, numSources, 2, chunkLen]
    auto inDims  = ctx->engine->getTensorShape("input");
    auto outDims = ctx->engine->getTensorShape("output");
    ctx->chunkLen   = inDims.d[2];
    ctx->numSources = outDims.d[1];
    *chunkLen   = ctx->chunkLen;
    *numSources = ctx->numSources;

    // 6. Allocate GPU memory
    cudaMalloc(&ctx->d_input,  2 * ctx->chunkLen * sizeof(float));
    cudaMalloc(&ctx->d_output, ctx->numSources * 2 * ctx->chunkLen * sizeof(float));
    cudaStreamCreate(&ctx->stream);

    // 7. Bind tensor addresses
    ctx->context->setTensorAddress("input",  ctx->d_input);
    ctx->context->setTensorAddress("output", ctx->d_output);

    return ctx;
}

extern "C" __declspec(dllexport)
int Trt_Process(void* hCtx, float* h_input, float* h_output)
{
    auto* ctx = (TrtContext*)hCtx;
    if (!ctx) return -1;

    size_t inSize  = 2 * ctx->chunkLen * sizeof(float);
    size_t outSize = ctx->numSources * 2 * ctx->chunkLen * sizeof(float);

    if (cudaMemcpyAsync(ctx->d_input, h_input, inSize,    cudaMemcpyHostToDevice, ctx->stream) != 0) return 1;
    if (!ctx->context->enqueueV3(ctx->stream))                                                        return 2;
    if (cudaMemcpyAsync(h_output, ctx->d_output, outSize, cudaMemcpyDeviceToHost, ctx->stream) != 0) return 3;

    cudaStreamSynchronize(ctx->stream);
    return 0;
}

extern "C" __declspec(dllexport)
void Trt_Destroy(void* hCtx)
{
    auto* ctx = (TrtContext*)hCtx;
    if (ctx) {
        if (ctx->d_input)  cudaFree(ctx->d_input);
        if (ctx->d_output) cudaFree(ctx->d_output);
        if (ctx->stream)   cudaStreamDestroy(ctx->stream);
        delete ctx;
    }
}