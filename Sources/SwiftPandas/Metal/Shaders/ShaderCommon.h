#ifndef ShaderCommon_h
#define ShaderCommon_h

#include <metal_stdlib>
using namespace metal;

// MurmurHash3-style finalizer for integer hashing
inline uint hash_uint(uint key) {
    key ^= key >> 16;
    key *= 0x85ebca6b;
    key ^= key >> 13;
    key *= 0xc2b2ae35;
    key ^= key >> 16;
    return key;
}

inline uint hash_int32(int key) {
    return hash_uint(as_type<uint>(key));
}

inline uint hash_combine(uint h1, uint h2) {
    return h1 ^ (h2 + 0x9e3779b9 + (h1 << 6) + (h1 >> 2));
}

constant int EMPTY_SLOT = -1;

// Check validity bit in a packed bitmap.
// BitVector stores [UInt64] words, accessed as pairs of uint32 on GPU.
// Bit i is at words[i/64], bit position (i%64), LSB-first.
inline bool is_valid(device const uint* validity_words, uint idx) {
    uint wordIdx = idx / 64;
    uint bitIdx = idx % 64;
    uint halfIdx = wordIdx * 2 + (bitIdx >= 32 ? 1 : 0);
    uint localBit = bitIdx % 32;
    return (validity_words[halfIdx] >> localBit) & 1;
}

#endif /* ShaderCommon_h */
