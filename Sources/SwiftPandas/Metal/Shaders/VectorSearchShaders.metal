// VectorSearchShaders.metal
// SwiftPandas
//
// Xcode/metallib twin of MetalShaders.vectorSearchShaders (SPM builds compile
// the embedded Swift string instead). Edit both together.

#include <metal_stdlib>
using namespace metal;

// One thread per candidate row of a compacted Float32 plane. Emits the raw
// cosine score per candidate; threshold/topK/tie-break run on the CPU side.
// sqrt(|query|^2) is computed once on the CPU and passed in. Zero-denominator
// rule matches the CPU contract: score 0 when either norm is 0.
kernel void swiftpandas_vector_batch_cosine(
    device const float* query    [[buffer(0)]],
    device const float* plane    [[buffer(1)]],
    device float* results        [[buffer(2)]],
    constant uint& dims          [[buffer(3)]],
    constant uint& count         [[buffer(4)]],
    constant float& sqrt_nq      [[buffer(5)]],
    uint tid [[thread_position_in_grid]])
{
    if (tid >= count) return;
    device const float* candidate = plane + (ulong)tid * (ulong)dims;
    float dot = 0.0f;
    float nc = 0.0f;
    for (uint k = 0; k < dims; ++k) {
        float v = candidate[k];
        dot = fma(query[k], v, dot);
        nc = fma(v, v, nc);
    }
    float denom = sqrt_nq * sqrt(nc);
    results[tid] = (denom == 0.0f) ? 0.0f : (dot / denom);
}
