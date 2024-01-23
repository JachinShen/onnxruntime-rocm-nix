/*************************************************************************
 * Copyright (c) 2022-2023, NVIDIA CORPORATION & AFFILIATES. All rights reserved.
 *
 * See LICENSE for license information.
 ************************************************************************/

#include <cuda_runtime.h>
#include <cfloat>
#include <iostream>
#include <type_traits>

#include "orttraining/training_ops/cuda/fp8/common.h"
#include "orttraining/training_ops/cuda/fp8/utils.cuh"

namespace onnxruntime {
namespace cuda {
namespace fp8 {

template <bool full_tile, int nvec_in, int nvec_out, typename IVec, typename OVec, typename CType>
inline __device__ void cast_and_transpose_regs(const IVec (&in)[nvec_out], OVec (&out_trans)[nvec_in],
                                               typename OVec::type* output_cast_tile, const size_t current_place,
                                               const size_t stride,
                                               CType& max,  // NOLINT(*)
                                               const CType scale, const bool valid_store) {
  using T = typename OVec::type;
  using OVecC = Vec<T, nvec_in>;
#pragma unroll
  for (unsigned int i = 0; i < nvec_out; ++i) {
    OVecC out_cast;
#pragma unroll
    for (unsigned int j = 0; j < nvec_in; ++j) {
      const CType tmp = static_cast<CType>(in[i].data.elt[j]);
      const T elt_o = T(scale * tmp);

      out_cast.data.elt[j] = elt_o;
      out_trans[j].data.elt[i] = elt_o;  // thread tile transpose

      __builtin_assume(max >= 0);
      max = fmaxf(fabsf(tmp), max);
    }
    if (full_tile || valid_store) {
      out_cast.store_to(output_cast_tile, current_place + stride * i);
    }
  }
}

template <bool full_tile, int nvec_in, int nvec_out, typename IVec, typename OVec, typename CVec, typename CType>
inline __device__ void cast_and_transpose_regs_partial_dbias(const IVec (&in)[nvec_out], OVec (&out_trans)[nvec_in],
                                                             CVec& out_dbias,  // NOLINT(*)
                                                             typename OVec::type* output_cast_tile,
                                                             const size_t current_place, const size_t stride,
                                                             CType& max,  // NOLINT(*)
                                                             const CType scale, const int dbias_shfl_src_lane,
                                                             const bool valid_store) {
  using T = typename OVec::type;
  using OVecC = Vec<T, nvec_in>;

  CVec step_dbias;
  step_dbias.clear();

#pragma unroll
  for (unsigned int i = 0; i < nvec_out; ++i) {
    OVecC out_cast;
#pragma unroll
    for (unsigned int j = 0; j < nvec_in; ++j) {
      const CType tmp = in[i].data.elt[j];
      const T elt_o = T(scale * tmp);

      /* dbias: thread tile local accumulation */
      step_dbias.data.elt[j] += tmp;

      out_cast.data.elt[j] = elt_o;
      out_trans[j].data.elt[i] = elt_o;  // thread tile transpose

      __builtin_assume(max >= 0);
      max = fmaxf(fabsf(tmp), max);
    }
    if (full_tile || valid_store) {
      out_cast.store_to(output_cast_tile, current_place + stride * i);
    }
  }

#pragma unroll
  for (unsigned int j = 0; j < nvec_in; ++j) {
    CType elt = step_dbias.data.elt[j];
    elt = __shfl_sync(0xffffffff, elt, dbias_shfl_src_lane);  // shuffle data in warp
    out_dbias.data.elt[j] += elt;
  }
}

// STUFF TO TUNE
constexpr unsigned int n_warps_per_tile = 4;
constexpr int desired_load_size = 8;
constexpr int desired_store_size = 8;

constexpr unsigned int max_threads_per_block = 256;
static_assert(n_warps_per_tile * THREADS_PER_WARP <= max_threads_per_block);
constexpr unsigned int cast_transpose_num_threads = n_warps_per_tile * THREADS_PER_WARP;

namespace {

template <typename IType, typename OType, typename CType>
struct CTDBiasParam {
  using InputType = IType;
  using OutputType = OType;
  using ComputeType = CType;
  const IType* input;
  OType* output_c;
  OType* output_t;
  const CType* scale_ptr;
  CType* amax;
  CType* workspace;
};

template <typename IType, typename IType2, typename OType, typename CType>
struct CTDBiasDGeluParam {
  using InputType = IType;
  using InputType2 = IType2;
  using OutputType = OType;
  using ComputeType = CType;
  const IType* input;
  const IType2* gelu_input;
  OType* output_c;
  OType* output_t;
  const CType* scale_ptr;
  CType* amax;
  CType* workspace;
};

}  // namespace

template <int nvec_in, int nvec_out, typename Param>
__global__ void __launch_bounds__(cast_transpose_num_threads)
    cast_transpose_dbias_kernel(const Param param, const size_t row_length, const size_t num_rows,
                                const size_t num_tiles) {
  using IType = typename Param::InputType;
  using OType = typename Param::OutputType;
  using CType = typename Param::ComputeType;
  using IVec = Vec<IType, nvec_in>;
  using OVec = Vec<OType, nvec_out>;
  using CVec = Vec<CType, nvec_in>;

  extern __shared__ char scratch[];

  const int warp_id = threadIdx.x / THREADS_PER_WARP;
  const unsigned int my_id_in_warp = threadIdx.x % THREADS_PER_WARP;
  const size_t num_tiles_x = row_length / (nvec_in * THREADS_PER_WARP);
  // const size_t num_tiles_y = num_rows / (nvec * THREADS_PER_WARP);
  const size_t tile_id = blockIdx.x * blockDim.x / (THREADS_PER_WARP * n_warps_per_tile) + warp_id / n_warps_per_tile;
  if (tile_id >= num_tiles) return;
  const size_t tile_id_x = tile_id % num_tiles_x;
  const size_t tile_id_y = tile_id / num_tiles_x;

  const IType* const my_input_tile =
      param.input + (tile_id_x * nvec_in + tile_id_y * row_length * nvec_out) * THREADS_PER_WARP;
  OType* const my_output_c_tile =
      param.output_c + (tile_id_x * nvec_in + tile_id_y * row_length * nvec_out) * THREADS_PER_WARP;
  OType* const my_output_t_tile =
      param.output_t + (tile_id_y * nvec_out + tile_id_x * num_rows * nvec_in) * THREADS_PER_WARP;
  CType* const my_partial_dbias_tile =
      param.workspace + (tile_id_x * (nvec_in * THREADS_PER_WARP) + tile_id_y * row_length);

  OVec* const my_scratch = reinterpret_cast<OVec*>(scratch) +
                           (my_id_in_warp + warp_id / n_warps_per_tile * THREADS_PER_WARP) * (THREADS_PER_WARP + 1);

  CVec* const my_dbias_scratch = reinterpret_cast<CVec*>(scratch);

  IVec in[2][nvec_out];
  const unsigned int warp_id_in_tile = warp_id % n_warps_per_tile;
  constexpr unsigned int n_iterations = THREADS_PER_WARP / n_warps_per_tile;
  OVec out_space[n_iterations][nvec_in];
  CVec partial_dbias;

  const size_t stride = row_length / nvec_in;
  const size_t output_stride = num_rows / nvec_out;
  size_t current_stride = warp_id_in_tile * n_iterations * nvec_out * stride;
  unsigned int my_place = (my_id_in_warp + THREADS_PER_WARP - warp_id_in_tile * n_iterations) % THREADS_PER_WARP;
  CType max = 0;
  const CType scale = param.scale_ptr != nullptr ? *param.scale_ptr : 1;

  partial_dbias.clear();

#pragma unroll
  for (unsigned int i = 0; i < nvec_out; ++i) {
    in[0][i].load_from(my_input_tile, current_stride + my_place + stride * i);
  }
#pragma unroll
  for (unsigned int i = 0; i < n_iterations; ++i) {
    const size_t current_place = current_stride + my_place;
    const unsigned int my_place_in = (my_place + THREADS_PER_WARP - 1) % THREADS_PER_WARP;
    const unsigned int current_in = (i + 1) % 2;
    if (i < n_iterations - 1) {
#pragma unroll
      for (unsigned int j = 0; j < nvec_out; ++j) {
        in[current_in][j].load_from(my_input_tile, current_stride + my_place_in + stride * (nvec_out + j));
      }
    }
    OVec out_trans[nvec_in];  // NOLINT(*)
    cast_and_transpose_regs_partial_dbias<true>(
        in[current_in ^ 1], out_trans, partial_dbias, my_output_c_tile, current_place, stride, max, scale,
        (my_id_in_warp + i + warp_id_in_tile * n_iterations) % THREADS_PER_WARP, true);

#pragma unroll
    for (unsigned int j = 0; j < nvec_in; ++j) {
      out_space[i][j].data.vec = out_trans[j].data.vec;
    }
    my_place = (my_place + THREADS_PER_WARP - 1) % THREADS_PER_WARP;
    current_stride += nvec_out * stride;
  }

  for (unsigned int i = 0; i < nvec_in; ++i) {
#pragma unroll
    for (unsigned int j = 0; j < n_iterations; ++j) {
      my_scratch[(my_id_in_warp + THREADS_PER_WARP - j - warp_id_in_tile * n_iterations) % THREADS_PER_WARP] =
          out_space[j][i];
    }
    __syncthreads();
    my_place = (my_id_in_warp + THREADS_PER_WARP - warp_id_in_tile * n_iterations) % THREADS_PER_WARP;
    current_stride = i * output_stride + warp_id_in_tile * n_iterations * output_stride * nvec_in;
    for (unsigned int j = 0; j < n_iterations; ++j) {
      my_scratch[j + warp_id_in_tile * n_iterations].store_to(my_output_t_tile, current_stride + my_place);
      my_place = (my_place + THREADS_PER_WARP - 1) % THREADS_PER_WARP;
      current_stride += output_stride * nvec_in;
    }
    __syncthreads();
  }

  my_dbias_scratch[threadIdx.x] = partial_dbias;
  __syncthreads();
  // TODO(ptredak): check if the regular reduction is better
  if (warp_id_in_tile == 0) {
#pragma unroll
    for (unsigned int i = 1; i < n_warps_per_tile; ++i) {
      CVec tmp = my_dbias_scratch[threadIdx.x + i * THREADS_PER_WARP];
#pragma unroll
      for (unsigned int j = 0; j < nvec_in; ++j) {
        partial_dbias.data.elt[j] += tmp.data.elt[j];
      }
    }

    partial_dbias.store_to(my_partial_dbias_tile, my_id_in_warp);
  }

  /* warp tile amax reduce*/
  max = reduce_max<cast_transpose_num_threads / THREADS_PER_WARP>(max, warp_id);

  if (threadIdx.x == 0) {
    static_assert(std::is_same<CType, float>::value);
    if (param.amax != nullptr) atomicMaxFloat(param.amax, max);
  }
}

template <int nvec_in, int nvec_out, typename Param>
__global__ void __launch_bounds__(cast_transpose_num_threads)
    cast_transpose_dbias_kernel_notaligned(const Param param, const size_t row_length, const size_t num_rows,
                                           const size_t num_tiles) {
  using IType = typename Param::InputType;
  using OType = typename Param::OutputType;
  using CType = typename Param::ComputeType;
  using IVec = Vec<IType, nvec_in>;
  using OVec = Vec<OType, nvec_out>;
  using CVec = Vec<CType, nvec_in>;

  extern __shared__ char scratch[];

  const int warp_id = threadIdx.x / THREADS_PER_WARP;
  const unsigned int my_id_in_warp = threadIdx.x % THREADS_PER_WARP;
  const size_t num_tiles_x = (row_length + nvec_in * THREADS_PER_WARP - 1) / (nvec_in * THREADS_PER_WARP);
  const size_t tile_id = blockIdx.x * blockDim.x / (THREADS_PER_WARP * n_warps_per_tile) + warp_id / n_warps_per_tile;
  if (tile_id >= num_tiles) return;
  const size_t tile_id_x = tile_id % num_tiles_x;
  const size_t tile_id_y = tile_id / num_tiles_x;

  const IType* const my_input_tile =
      param.input + (tile_id_x * nvec_in + tile_id_y * row_length * nvec_out) * THREADS_PER_WARP;
  OType* const my_output_c_tile =
      param.output_c + (tile_id_x * nvec_in + tile_id_y * row_length * nvec_out) * THREADS_PER_WARP;
  OType* const my_output_t_tile =
      param.output_t + (tile_id_y * nvec_out + tile_id_x * num_rows * nvec_in) * THREADS_PER_WARP;
  CType* const my_partial_dbias_tile =
      param.workspace + (tile_id_x * (nvec_in * THREADS_PER_WARP) + tile_id_y * row_length);

  const size_t stride = row_length / nvec_in;
  const size_t output_stride = num_rows / nvec_out;
  const size_t row_length_rest = stride - tile_id_x * THREADS_PER_WARP;
  const size_t row_height_rest = output_stride - tile_id_y * THREADS_PER_WARP;
  const unsigned int tile_length = row_length_rest > THREADS_PER_WARP ? THREADS_PER_WARP : row_length_rest;
  const unsigned int tile_height = row_height_rest > THREADS_PER_WARP ? THREADS_PER_WARP : row_height_rest;

  OVec* const my_scratch = reinterpret_cast<OVec*>(scratch) +
                           (my_id_in_warp + warp_id / n_warps_per_tile * THREADS_PER_WARP) * (THREADS_PER_WARP + 1);

  CVec* const my_dbias_scratch = reinterpret_cast<CVec*>(scratch);

  IVec in[2][nvec_out];
  const unsigned int warp_id_in_tile = warp_id % n_warps_per_tile;
  constexpr unsigned int n_iterations = THREADS_PER_WARP / n_warps_per_tile;
  OVec out_space[n_iterations][nvec_in];
  CVec partial_dbias;

  size_t current_stride = warp_id_in_tile * n_iterations * nvec_out * stride;
  unsigned int my_place = (my_id_in_warp + THREADS_PER_WARP - warp_id_in_tile * n_iterations) % THREADS_PER_WARP;
  CType max = 0;
  const CType scale = param.scale_ptr != nullptr ? *param.scale_ptr : 1;

  partial_dbias.clear();

  {
    const bool valid_load = my_place < tile_length && warp_id_in_tile * n_iterations < tile_height;
#pragma unroll
    for (unsigned int i = 0; i < nvec_out; ++i) {
      if (valid_load) {
        in[0][i].load_from(my_input_tile, current_stride + my_place + stride * i);
      } else {
        in[0][i].clear();
      }
    }
  }
#pragma unroll
  for (unsigned int i = 0; i < n_iterations; ++i) {
    const size_t current_place = current_stride + my_place;
    const unsigned int my_place_in = (my_place + THREADS_PER_WARP - 1) % THREADS_PER_WARP;
    const unsigned int current_in = (i + 1) % 2;
    if (i < n_iterations - 1) {
      const bool valid_load = my_place_in < tile_length && warp_id_in_tile * n_iterations + i + 1 < tile_height;
#pragma unroll
      for (unsigned int j = 0; j < nvec_out; ++j) {
        if (valid_load) {
          in[current_in][j].load_from(my_input_tile, current_stride + my_place_in + stride * (nvec_out + j));
        } else {
          in[current_in][j].clear();
        }
      }
    }
    OVec out_trans[nvec_in];  // NOLINT(*)
    const bool valid_store = my_place < tile_length && warp_id_in_tile * n_iterations + i < tile_height;
    cast_and_transpose_regs_partial_dbias<false>(
        in[current_in ^ 1], out_trans, partial_dbias, my_output_c_tile, current_place, stride, max, scale,
        (my_id_in_warp + i + warp_id_in_tile * n_iterations) % THREADS_PER_WARP, valid_store);

#pragma unroll
    for (unsigned int j = 0; j < nvec_in; ++j) {
      out_space[i][j].data.vec = out_trans[j].data.vec;
    }
    my_place = (my_place + THREADS_PER_WARP - 1) % THREADS_PER_WARP;
    current_stride += nvec_out * stride;
  }

  for (unsigned int i = 0; i < nvec_in; ++i) {
#pragma unroll
    for (unsigned int j = 0; j < n_iterations; ++j) {
      my_scratch[(my_id_in_warp + THREADS_PER_WARP - j - warp_id_in_tile * n_iterations) % THREADS_PER_WARP] =
          out_space[j][i];
    }
    __syncthreads();
    my_place = (my_id_in_warp + THREADS_PER_WARP - warp_id_in_tile * n_iterations) % THREADS_PER_WARP;
    current_stride = i * output_stride + warp_id_in_tile * n_iterations * output_stride * nvec_in;
    for (unsigned int j = 0; warp_id_in_tile * n_iterations + j < tile_length; ++j) {
      const bool valid_store = my_place < tile_height;
      if (valid_store) {
        my_scratch[j + warp_id_in_tile * n_iterations].store_to(my_output_t_tile, current_stride + my_place);
      }
      my_place = (my_place + THREADS_PER_WARP - 1) % THREADS_PER_WARP;
      current_stride += output_stride * nvec_in;
    }
    __syncthreads();
  }

  my_dbias_scratch[threadIdx.x] = partial_dbias;
  __syncthreads();
  // TODO(ptredak): check if the regular reduction is better
  if (warp_id_in_tile == 0) {
#pragma unroll
    for (unsigned int i = 1; i < n_warps_per_tile; ++i) {
      CVec tmp = my_dbias_scratch[threadIdx.x + i * THREADS_PER_WARP];
#pragma unroll
      for (unsigned int j = 0; j < nvec_in; ++j) {
        partial_dbias.data.elt[j] += tmp.data.elt[j];
      }
    }

    if (my_id_in_warp < tile_length) {
      partial_dbias.store_to(my_partial_dbias_tile, my_id_in_warp);
    }
  }

  /* warp tile amax reduce*/
  max = reduce_max<cast_transpose_num_threads / THREADS_PER_WARP>(max, warp_id);

  if (threadIdx.x == 0) {
    static_assert(std::is_same<CType, float>::value);
    if (param.amax != nullptr) atomicMaxFloat(param.amax, max);
  }
}

constexpr size_t reduce_dbias_num_threads = 256;

template <int nvec, typename ComputeType, typename OutputType>
__global__ void __launch_bounds__(reduce_dbias_num_threads)
    reduce_dbias_kernel(OutputType* const dbias_output, const ComputeType* const dbias_partial, const int row_length,
                        const int num_rows) {
  using ComputeVec = Vec<ComputeType, nvec>;
  using OutputVec = Vec<OutputType, nvec>;

  const int thread_id = blockIdx.x * blockDim.x + threadIdx.x;

  if (thread_id * nvec >= row_length) return;

  const ComputeType* const thread_in_base = dbias_partial + thread_id * nvec;
  OutputType* const thread_out_base = dbias_output + thread_id * nvec;

  const int stride_in_vec = row_length / nvec;

  ComputeVec ldg_vec;
  ComputeVec acc_vec;
  acc_vec.clear();
  for (int i = 0; i < num_rows; ++i) {
    ldg_vec.load_from(thread_in_base, i * stride_in_vec);
#pragma unroll
    for (int e = 0; e < nvec; ++e) {
      acc_vec.data.elt[e] += ldg_vec.data.elt[e];
    }
  }

  OutputVec stg_vec;
#pragma unroll
  for (int e = 0; e < nvec; ++e) {
    stg_vec.data.elt[e] = OutputType(acc_vec.data.elt[e]);
  }
  stg_vec.store_to(thread_out_base, 0);
}

template <typename InputType>
void reduce_dbias(const fp32* workspace, InputType* dbias_data, const size_t row_length, const size_t num_rows,
                  const int nvec_out, cudaStream_t stream) {
  constexpr int reduce_dbias_store_bytes = 8;  // stg.64
  constexpr int reduce_dbias_nvec = reduce_dbias_store_bytes / sizeof(InputType);
  ORT_ENFORCE(row_length % reduce_dbias_nvec == 0, "Unsupported shape.");
  const size_t reduce_dbias_row_length = row_length;
  const size_t reduce_dbias_num_rows = DIVUP(num_rows, static_cast<size_t>(nvec_out * THREADS_PER_WARP));
  const size_t reduce_dbias_num_blocks = DIVUP(row_length, reduce_dbias_num_threads * reduce_dbias_nvec);

  reduce_dbias_kernel<reduce_dbias_nvec, fp32, InputType>
      <<<reduce_dbias_num_blocks, reduce_dbias_num_threads, 0, stream>>>(dbias_data, workspace, reduce_dbias_row_length,
                                                                         reduce_dbias_num_rows);
}

template <typename OutputType>
size_t GetCastTransposeBiasWorkspaceSize(const size_t row_length, const size_t num_rows) {
  typedef typename MappedType<OutputType>::CudaType CudaOutputType;
  constexpr int otype_size = sizeof(CudaOutputType);
  constexpr int nvec_out = desired_store_size / otype_size;
  const size_t tile_size_y = (nvec_out * THREADS_PER_WARP);
  const size_t num_rows_partial_dbias = DIVUP(num_rows, tile_size_y);
  return num_rows_partial_dbias * row_length;
}

template <typename InputType, typename OutputType>
void CastTransposeBias(cudaStream_t stream, const InputType* input_data, OutputType* cast_output_data,
                       OutputType* transposed_output_data, InputType* dbias_data, fp32* workspace, const fp32* scale,
                       fp32* amax, const size_t row_length, const size_t num_rows) {
  typedef typename MappedType<InputType>::CudaType CudaInputType;
  typedef typename MappedType<OutputType>::CudaType CudaOutputType;
  const CudaInputType* cuda_input_data = reinterpret_cast<const CudaInputType*>(input_data);
  CudaOutputType* cuda_cast_output_data = reinterpret_cast<CudaOutputType*>(cast_output_data);
  CudaOutputType* cuda_transposed_output_data = reinterpret_cast<CudaOutputType*>(transposed_output_data);
  CudaInputType* cuda_dbias_data = reinterpret_cast<CudaInputType*>(dbias_data);

  constexpr int itype_size = sizeof(CudaInputType);
  constexpr int otype_size = sizeof(CudaOutputType);
  constexpr int nvec_in = desired_load_size / itype_size;
  constexpr int nvec_out = desired_store_size / otype_size;
  ORT_ENFORCE(row_length % nvec_in == 0, "Unsupported shape.");
  ORT_ENFORCE(num_rows % nvec_out == 0, "Unsupported shape.");

  const size_t n_tiles = DIVUP(row_length, static_cast<size_t>(nvec_in * THREADS_PER_WARP)) *
                         DIVUP(num_rows, static_cast<size_t>(nvec_out * THREADS_PER_WARP));
  const size_t n_warps_per_block = cast_transpose_num_threads / THREADS_PER_WARP;
  const size_t n_blocks = DIVUP(n_tiles * n_warps_per_tile, n_warps_per_block);

  const bool full_tile =
      row_length % (nvec_in * THREADS_PER_WARP) == 0 && num_rows % (nvec_out * THREADS_PER_WARP) == 0;

  using ComputeType = fp32;
  constexpr size_t shared_size_transpose =
      cast_transpose_num_threads / n_warps_per_tile * (THREADS_PER_WARP + 1) * sizeof(Vec<CudaOutputType, nvec_out>);
  constexpr size_t shared_size_dbias = cast_transpose_num_threads * sizeof(Vec<ComputeType, nvec_in>);
  static_assert(shared_size_transpose >= shared_size_dbias);
  using Param = CTDBiasParam<CudaInputType, CudaOutputType, ComputeType>;
  Param param;
  param.input = cuda_input_data;
  param.output_c = cuda_cast_output_data;
  param.output_t = cuda_transposed_output_data;
  param.scale_ptr = scale;
  param.amax = amax;
  param.workspace = workspace;

  if (full_tile) {
    cudaFuncSetAttribute(cast_transpose_dbias_kernel<nvec_in, nvec_out, Param>,
                         cudaFuncAttributePreferredSharedMemoryCarveout, 100);
    cast_transpose_dbias_kernel<nvec_in, nvec_out, Param>
        <<<n_blocks, cast_transpose_num_threads, shared_size_transpose, stream>>>(param, row_length, num_rows, n_tiles);
  } else {
    cudaFuncSetAttribute(cast_transpose_dbias_kernel_notaligned<nvec_in, nvec_out, Param>,
                         cudaFuncAttributePreferredSharedMemoryCarveout, 100);
    cast_transpose_dbias_kernel_notaligned<nvec_in, nvec_out, Param>
        <<<n_blocks, cast_transpose_num_threads, shared_size_transpose, stream>>>(param, row_length, num_rows, n_tiles);
  }

  reduce_dbias<CudaInputType>(workspace, cuda_dbias_data, row_length, num_rows, nvec_out, stream);
}

#define SPECIALIZED_CAST_TRANSPOSE_BIAS_IMPL(InputType, OutputType)                                              \
  template size_t GetCastTransposeBiasWorkspaceSize<OutputType>(const size_t row_length, const size_t num_rows); \
  template void CastTransposeBias<InputType, OutputType>(                                                        \
      cudaStream_t stream, const InputType* input_data, OutputType* cast_output_data,                            \
      OutputType* transposed_output_data, InputType* dbias_data, fp32* workspace, const fp32* scale, fp32* amax, \
      const size_t row_length, const size_t num_rows);

SPECIALIZED_CAST_TRANSPOSE_BIAS_IMPL(MLFloat16, Float8E5M2)

#undef SPECIALIZED_CAST_TRANSPOSE_BIAS_IMPL

}  // namespace fp8
}  // namespace cuda
}  // namespace onnxruntime