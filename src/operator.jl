export Operator
module Operator

using CUDA
using GemmKernels
using GemmKernels.Tiling

# -------------------------------------
# Default definition for padded layouts
# -------------------------------------

for f in (:fragtype_a, :fragtype_b, :fragtype_accum, :load_a, :load_b, :load_c, :store_d)
    @eval @inline $f(op, ::Type{Layout.Padded{L, P}}, args...) where {L, P} = $f(op, L, args...)
end

# ----
# WMMA
# ----

struct WMMAOp{M, N, K} end

@inline shape(::Type{WMMAOp{M, N, K}}) where {M, N, K} = (M = M, N = N, K = K)

# convert_index_func: function used to transpose the index in case of a row-major layout
for (layout_type, wmma_layout_type, convert_index_func) in [
                                        (Layout.AlignedColMajor, WMMA.ColMajor, identity),
                                        (Layout.AlignedRowMajor, WMMA.RowMajor, x -> reverse(Tuple(x)))
                                       ]
    @eval begin
        @inline fragtype_a(::Type{WMMAOp{16, 16, 16}}, ::Type{$layout_type{Float16}}) = WMMA.Fragment{16, 16, 16, 16, Float16, $wmma_layout_type, WMMA.MatrixA}
        @inline fragtype_b(::Type{WMMAOp{16, 16, 16}}, ::Type{$layout_type{Float16}}) = WMMA.Fragment{16, 16, 16, 16, Float16, $wmma_layout_type, WMMA.MatrixB}
        @inline fragtype_accum(::Type{WMMAOp{16, 16, 16}}, ::Type{$layout_type{Float32}}) = WMMA.Fragment{16, 16, 16, 8, Float32, WMMA.Unspecified, WMMA.Accumulator}

        @inline function load_a(::Type{WMMAOp{M, N, K}}, ::Type{$layout_type{Float16}}, workspace, tile::Tile) where {M, N, K}
            conf = WMMA.Config{M, N, K, Float32}

            linear_base = linearise($convert_index_func(tile.base), size(workspace))
            linear_offset = linearise($convert_index_func(tile.offset), size(workspace))

            ptr = pointer(workspace, linear_base) + (linear_offset - 1) * sizeof(Float16)
            return WMMA.load_a(ptr, size(workspace, 1), $wmma_layout_type, conf)
        end

        @inline function load_b(::Type{WMMAOp{M, N, K}}, ::Type{$layout_type{Float16}}, workspace, tile::Tile) where {M, N, K}
            conf = WMMA.Config{M, N, K, Float32}

            linear_base = linearise($convert_index_func(tile.base), size(workspace))
            linear_offset = linearise($convert_index_func(tile.offset), size(workspace))

            ptr = pointer(workspace, linear_base) + (linear_offset - 1) * sizeof(Float16)
            return WMMA.load_b(ptr, size(workspace, 1), $wmma_layout_type, conf)
        end

        @inline function load_c(::Type{WMMAOp{M, N, K}}, ::Type{$layout_type{Float32}}, workspace, tile::Tile) where {M, N, K}
            conf = WMMA.Config{M, N, K, Float32}

            linear_base = linearise($convert_index_func(tile.base), size(workspace))
            linear_offset = linearise($convert_index_func(tile.offset), size(workspace))

            ptr = pointer(workspace, linear_base) + (linear_offset - 1) * sizeof(Float32)
            return WMMA.load_c(ptr, size(workspace, 1), $wmma_layout_type, conf)
        end

        @inline function store_d(::Type{WMMAOp{M, N, K}}, ::Type{$layout_type{Float32}}, workspace, frag, tile::Tile) where {M, N, K}
            conf = WMMA.Config{M, N, K, Float32}

            linear_base = linearise($convert_index_func(tile.base), size(workspace))
            linear_offset = linearise($convert_index_func(tile.offset), size(workspace))

            ptr = pointer(workspace, linear_base) + (linear_offset - 1) * sizeof(Float32)
            WMMA.store_d(ptr, frag, size(workspace, 1), $wmma_layout_type, conf)
        end
    end
end

function mma(::Type{WMMAOp{M, N, K}}, a_frag, b_frag, c_frag) where {M, N, K}
    conf = WMMA.Config{M, N, K, Float32}
    return WMMA.mma(a_frag, b_frag, c_frag, conf)
end

# -----------
# WMMAComplex
# -----------

struct WMMAComplexOp{M, N, K} end

@inline shape(::Type{WMMAComplexOp{M, N, K}}) where {M, N, K} = (M = M, N = N, K = K)

# convert_index_func: function used to transpose the index in case of a row-major layout
for (layout_type, wmma_layout_type, convert_index_func) in [
                                        (Layout.SplitColMajor, WMMA.ColMajor, identity),
                                        (Layout.SplitRowMajor, WMMA.RowMajor, x -> reverse(Tuple(x))),
                                       ]
    @eval begin
        @inline fragtype_a(::Type{WMMAComplexOp{16, 16, 16}}, ::Type{$layout_type{Float16}}) = NTuple{2, WMMA.Fragment{16, 16, 16, 16, Float16, $wmma_layout_type, WMMA.MatrixA}}
        @inline fragtype_b(::Type{WMMAComplexOp{16, 16, 16}}, ::Type{$layout_type{Float16}}) = NTuple{2, WMMA.Fragment{16, 16, 16, 16, Float16, $wmma_layout_type, WMMA.MatrixB}}
        @inline fragtype_accum(::Type{WMMAComplexOp{16, 16, 16}}, ::Type{$layout_type{Float32}}) = NTuple{2, WMMA.Fragment{16, 16, 16, 8, Float32, WMMA.Unspecified, WMMA.Accumulator}}

        @inline function load_a(::Type{WMMAComplexOp{M, N, K}}, ::Type{$layout_type{Float16}}, workspace, tile::Tile) where {M, N, K}
            conf = WMMA.Config{16, 16, 16, Float32}
            ind = linearise($convert_index_func(tile.index), (size(workspace)[1], size(workspace)[2]))

            return (WMMA.load_a(pointer(workspace, ind), size(workspace)[1], $wmma_layout_type, conf),
                    WMMA.load_a(pointer(workspace, ind + size(workspace)[1] * size(workspace)[2]), size(workspace)[1], $wmma_layout_type, conf))
        end

        @inline function load_b(::Type{WMMAComplexOp{M, N, K}}, ::Type{$layout_type{Float16}}, workspace, tile::Tile) where {M, N, K}
            conf = WMMA.Config{16, 16, 16, Float32}
            ind = linearise($convert_index_func(tile.index), (size(workspace)[1], size(workspace)[2]))

            return (WMMA.load_b(pointer(workspace, ind), size(workspace)[1], $wmma_layout_type, conf),
                    WMMA.load_b(pointer(workspace, ind + size(workspace)[1] * size(workspace)[2]), size(workspace)[1], $wmma_layout_type, conf))
        end

        @inline function load_c(::Type{WMMAComplexOp{M, N, K}}, ::Type{$layout_type{Float32}}, workspace, tile::Tile) where {M, N, K}
            conf = WMMA.Config{M, N, K, Float32}
            ind = linearise($convert_index_func(tile.index), (size(workspace)[1], size(workspace)[2]))

            return (WMMA.load_c(pointer(workspace, ind), size(workspace)[1], $wmma_layout_type, conf),
                    WMMA.load_c(pointer(workspace, ind + size(workspace)[1] * size(workspace)[2]), size(workspace)[1], $wmma_layout_type, conf))
        end

        @inline function store_d(::Type{WMMAComplexOp{M, N, K}}, ::Type{$layout_type{Float32}}, workspace, frag, tile::Tile) where {M, N, K}
            conf = WMMA.Config{M, N, K, Float32}
            ind = linearise($convert_index_func(tile.index), (size(workspace)[1], size(workspace)[2]))

            WMMA.store_d(pointer(workspace, ind), frag[1], size(workspace)[1], $wmma_layout_type, conf)
            WMMA.store_d(pointer(workspace, ind + size(workspace)[1] * size(workspace)[2]), frag[2], size(workspace)[1], $wmma_layout_type, conf)
        end
    end
end

using LLVM

multiply_fp16(a::Float16, b::Float16) =
    Base.bitcast(Float16,
                 LLVM.Interop.@asmcall(
                                       "{mul.f16 \$0,\$1,\$2;}",
                                       "=h,h,h",
                                       false,
                                       Int16,
                                       Tuple{Int16, Int16},
                                       Base.bitcast(Int16, a),
                                       Base.bitcast(Int16, b)
                                      )
                )

@inline function mma(::Type{WMMAComplexOp{M, N, K}}, a_frag, b_frag, c_frag) where {M, N, K}
    conf = WMMA.Config{16, 16, 16, Float32}

    c_re = c_frag[1]
    c_im = c_frag[2]

    c_re = WMMA.mma(a_frag[1],  b_frag[1], c_re, conf)
    c_re = WMMA.mma(multiply_fp16.(a_frag[2], Float16(-1)), b_frag[2], c_re, conf)

    c_im = WMMA.mma(a_frag[1], b_frag[2], c_im, conf)
    c_im = WMMA.mma(a_frag[2], b_frag[1], c_im, conf)

    return (c_re, c_im)
end

# --------
# WMMADual
# --------

struct WMMADualOp{M, N, K} end

@inline shape(::Type{WMMADualOp{M, N, K}}) where {M, N, K} = (M = M, N = N, K = K)

@inline fragtype_a(::Type{WMMADualOp{16, 16, 16}}, ::Type{Layout.SplitColMajor{Float16}}) = NTuple{2, WMMA.Fragment{16, 16, 16, 16, Float16, WMMA.ColMajor, WMMA.MatrixA}}
@inline fragtype_b(::Type{WMMADualOp{16, 16, 16}}, ::Type{Layout.SplitColMajor{Float16}}) = NTuple{2, WMMA.Fragment{16, 16, 16, 16, Float16, WMMA.ColMajor, WMMA.MatrixB}}
@inline fragtype_accum(::Type{WMMADualOp{16, 16, 16}}, ::Type{Layout.SplitColMajor{Float32}}) = NTuple{2, WMMA.Fragment{16, 16, 16, 8, Float32, WMMA.Unspecified, WMMA.Accumulator}}

@inline function load_a(::Type{WMMADualOp{M, N, K}}, ::Type{Layout.SplitColMajor{Float16}}, workspace, tile::Tile) where {M, N, K}
    conf = WMMA.Config{16, 16, 16, Float32}
    ind = linearise(tile.index, (size(workspace)[1], size(workspace)[2]))

    return (WMMA.load_a(pointer(workspace, ind), size(workspace)[1], WMMA.ColMajor, conf),
            WMMA.load_a(pointer(workspace, ind + size(workspace)[1] * size(workspace)[2]), size(workspace)[1], WMMA.ColMajor, conf))
end

@inline function load_b(::Type{WMMADualOp{M, N, K}}, ::Type{Layout.SplitColMajor{Float16}}, workspace, tile::Tile) where {M, N, K}
    conf = WMMA.Config{16, 16, 16, Float32}
    ind = linearise(tile.index, (size(workspace)[1], size(workspace)[2]))

    return (WMMA.load_b(pointer(workspace, ind), size(workspace)[1], WMMA.ColMajor, conf),
            WMMA.load_b(pointer(workspace, ind + size(workspace)[1] * size(workspace)[2]), size(workspace)[1], WMMA.ColMajor, conf))
end

@inline function load_c(::Type{WMMADualOp{M, N, K}}, ::Type{Layout.SplitColMajor{Float32}}, workspace, tile::Tile) where {M, N, K}
    conf = WMMA.Config{M, N, K, Float32}
    ind = linearise(tile.index, (size(workspace)[1], size(workspace)[2]))

    return (WMMA.load_c(pointer(workspace, ind), size(workspace)[1], WMMA.ColMajor, conf),
            WMMA.load_c(pointer(workspace, ind + size(workspace)[1] * size(workspace)[2]), size(workspace)[1], WMMA.ColMajor, conf))
end

@inline function store_d(::Type{WMMADualOp{M, N, K}}, ::Type{Layout.SplitColMajor{Float32}}, workspace, frag, tile::Tile) where {M, N, K}
    conf = WMMA.Config{M, N, K, Float32}
    ind = linearise(tile.index, (size(workspace)[1], size(workspace)[2]))

    WMMA.store_d(pointer(workspace, ind), frag[1], size(workspace)[1], WMMA.ColMajor, conf)
    WMMA.store_d(pointer(workspace, ind + size(workspace)[1] * size(workspace)[2]), frag[2], size(workspace)[1], WMMA.ColMajor, conf)
end

@inline function mma(::Type{WMMADualOp{M, N, K}}, a_frag, b_frag, c_frag) where {M, N, K}
    conf = WMMA.Config{16, 16, 16, Float32}

    c_re = c_frag[1]
    c_du = c_frag[2]

    c_re = WMMA.mma(a_frag[1],  b_frag[1], c_re, conf)

    c_du = WMMA.mma(a_frag[1], b_frag[2], c_du, conf)
    c_du = WMMA.mma(a_frag[2], b_frag[1], c_du, conf)

    return (c_re, c_du)
end

end
