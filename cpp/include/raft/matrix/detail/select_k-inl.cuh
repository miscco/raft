/*

 * Copyright (c) 2022-2024, NVIDIA CORPORATION.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#pragma once

#include <type_traits>

#include "select_radix.cuh"
#include "select_warpsort.cuh"

#include <raft/core/device_csr_matrix.hpp>
#include <raft/core/device_mdarray.hpp>
#include <raft/core/device_mdspan.hpp>
#include <raft/core/nvtx.hpp>
#include <raft/matrix/copy.cuh>
#include <raft/matrix/gather.cuh>
#include <raft/matrix/init.cuh>
#include <raft/matrix/select_k_types.hpp>

#include <raft/core/resource/thrust_policy.hpp>
#include <rmm/cuda_stream_view.hpp>
#include <rmm/mr/device/device_memory_resource.hpp>
#include <thrust/scan.h>

namespace raft::matrix::detail {

/**
 * Predict the fastest select_k algorithm based on the number of rows/cols/k
 *
 * The body of this method is automatically generated, using a DecisionTree
 * to predict the fastest algorithm based off of thousands of trial runs
 * on different values of rows/cols/k. The decision tree is converted to c++
 * code, which is cut and paste below.
 *
 * NOTE: The code to generate is in cpp/scripts/heuristics/select_k, running the
 * 'generate_heuristic' notebook there will replace the body of this function
 * with the latest learned heuristic
 */
inline SelectAlgo choose_select_k_algorithm(size_t rows, size_t cols, int k)
{
  if (k > 256) {
    if (cols > 16862) {
      if (rows > 1020) {
        return SelectAlgo::kRadix11bitsExtraPass;
      } else {
        return SelectAlgo::kRadix11bits;
      }
    } else {
      return SelectAlgo::kRadix11bitsExtraPass;
    }
  } else {
    if (k > 2) {
      if (cols > 22061) {
        return SelectAlgo::kWarpDistributedShm;
      } else {
        if (rows > 198) {
          return SelectAlgo::kWarpDistributedShm;
        } else {
          return SelectAlgo::kWarpImmediate;
        }
      }
    } else {
      return SelectAlgo::kWarpImmediate;
    }
  }
}

/**
 * Performs a segmented sorting of a keys array with respect to
 * the segments of a values array.
 * @tparam KeyT
 * @tparam ValT
 * @param handle
 * @param values
 * @param keys
 * @param n_segments
 * @param k
 * @param select_min
 */
template <typename KeyT, typename ValT>
void segmented_sort_by_key(raft::resources const& handle,
                           KeyT* keys,
                           ValT* values,
                           size_t n_segments,
                           size_t n_elements,
                           const ValT* offsets,
                           bool asc)
{
  auto stream    = raft::resource::get_cuda_stream(handle);
  auto out_inds  = raft::make_device_vector<ValT, ValT>(handle, n_elements);
  auto out_dists = raft::make_device_vector<KeyT, ValT>(handle, n_elements);

  // Determine temporary device storage requirements
  auto d_temp_storage       = raft::make_device_vector<char, int>(handle, 0);
  size_t temp_storage_bytes = 0;
  if (asc) {
    cub::DeviceSegmentedRadixSort::SortPairs((void*)d_temp_storage.data_handle(),
                                             temp_storage_bytes,
                                             keys,
                                             out_dists.data_handle(),
                                             values,
                                             out_inds.data_handle(),
                                             n_elements,
                                             n_segments,
                                             offsets,
                                             offsets + 1,
                                             0,
                                             sizeof(ValT) * 8,
                                             stream);
  } else {
    cub::DeviceSegmentedRadixSort::SortPairsDescending((void*)d_temp_storage.data_handle(),
                                                       temp_storage_bytes,
                                                       keys,
                                                       out_dists.data_handle(),
                                                       values,
                                                       out_inds.data_handle(),
                                                       n_elements,
                                                       n_segments,
                                                       offsets,
                                                       offsets + 1,
                                                       0,
                                                       sizeof(ValT) * 8,
                                                       stream);
  }

  d_temp_storage = raft::make_device_vector<char, int>(handle, temp_storage_bytes);

  if (asc) {
    // Run sorting operation
    cub::DeviceSegmentedRadixSort::SortPairs((void*)d_temp_storage.data_handle(),
                                             temp_storage_bytes,
                                             keys,
                                             out_dists.data_handle(),
                                             values,
                                             out_inds.data_handle(),
                                             n_elements,
                                             n_segments,
                                             offsets,
                                             offsets + 1,
                                             0,
                                             sizeof(ValT) * 8,
                                             stream);

  } else {
    // Run sorting operation
    cub::DeviceSegmentedRadixSort::SortPairsDescending((void*)d_temp_storage.data_handle(),
                                                       temp_storage_bytes,
                                                       keys,
                                                       out_dists.data_handle(),
                                                       values,
                                                       out_inds.data_handle(),
                                                       n_elements,
                                                       n_segments,
                                                       offsets,
                                                       offsets + 1,
                                                       0,
                                                       sizeof(ValT) * 8,
                                                       stream);
  }

  raft::copy(values, out_inds.data_handle(), out_inds.size(), stream);
  raft::copy(keys, out_dists.data_handle(), out_dists.size(), stream);
}

template <typename KeyT, typename ValT>
void segmented_sort_by_key(raft::resources const& handle,
                           raft::device_vector_view<const ValT, ValT> offsets,
                           raft::device_vector_view<KeyT, ValT> keys,
                           raft::device_vector_view<ValT, ValT> values,
                           bool asc)
{
  RAFT_EXPECTS(keys.size() == values.size(),
               "Keys and values must contain the same number of elements.");
  segmented_sort_by_key<KeyT, ValT>(handle,
                                    keys.data_handle(),
                                    values.data_handle(),
                                    offsets.size() - 1,
                                    keys.size(),
                                    offsets.data_handle(),
                                    asc);
}

/**
 * Select k smallest or largest key/values from each row in the input data.
 *
 * If you think of the input data `in_val` as a row-major matrix with `len` columns and
 * `batch_size` rows, then this function selects `k` smallest/largest values in each row and fills
 * in the row-major matrix `out_val` of size (batch_size, k).
 *
 * @tparam T
 *   the type of the keys (what is being compared).
 * @tparam IdxT
 *   the index type (what is being selected together with the keys).
 *
 * @param[in] in_val
 *   contiguous device array of inputs of size (len * batch_size);
 *   these are compared and selected.
 * @param[in] in_idx
 *   contiguous device array of inputs of size (len * batch_size);
 *   typically, these are indices of the corresponding in_val.
 * @param batch_size
 *   number of input rows, i.e. the batch size.
 * @param len
 *   length of a single input array (row); also sometimes referred as n_cols.
 *   Invariant: len >= k.
 * @param k
 *   the number of outputs to select in each input row.
 * @param[out] out_val
 *   contiguous device array of outputs of size (k * batch_size);
 *   the k smallest/largest values from each row of the `in_val`.
 * @param[out] out_idx
 *   contiguous device array of outputs of size (k * batch_size);
 *   the payload selected together with `out_val`.
 * @param select_min
 *   whether to select k smallest (true) or largest (false) keys.
 * @param stream
 * @param mr an optional memory resource to use across the calls (you can provide a large enough
 *           memory pool here to avoid memory allocations within the call).
 */
template <typename T, typename IdxT>
void select_k(raft::resources const& handle,
              const T* in_val,
              const IdxT* in_idx,
              size_t batch_size,
              size_t len,
              int k,
              T* out_val,
              IdxT* out_idx,
              bool select_min,
              rmm::mr::device_memory_resource* mr = nullptr,
              bool sorted                         = false,
              SelectAlgo algo                     = SelectAlgo::kAuto)
{
  common::nvtx::range<common::nvtx::domain::raft> fun_scope(
    "matrix::select_k(batch_size = %zu, len = %zu, k = %d)", batch_size, len, k);

  if (mr == nullptr) { mr = rmm::mr::get_current_device_resource(); }

  if (algo == SelectAlgo::kAuto) { algo = choose_select_k_algorithm(batch_size, len, k); }

  auto stream = raft::resource::get_cuda_stream(handle);
  switch (algo) {
    case SelectAlgo::kRadix8bits:
    case SelectAlgo::kRadix11bits:
    case SelectAlgo::kRadix11bitsExtraPass: {
      if (algo == SelectAlgo::kRadix8bits) {
        detail::select::radix::select_k<T, IdxT, 8, 512>(in_val,
                                                         in_idx,
                                                         batch_size,
                                                         len,
                                                         k,
                                                         out_val,
                                                         out_idx,
                                                         select_min,
                                                         true,  // fused_last_filter
                                                         stream,
                                                         mr);

      } else {
        bool fused_last_filter = algo == SelectAlgo::kRadix11bits;
        detail::select::radix::select_k<T, IdxT, 11, 512>(in_val,
                                                          in_idx,
                                                          batch_size,
                                                          len,
                                                          k,
                                                          out_val,
                                                          out_idx,
                                                          select_min,
                                                          fused_last_filter,
                                                          stream,
                                                          mr);
      }
      if (sorted) {
        auto offsets = raft::make_device_vector<IdxT, IdxT>(handle, (IdxT)(batch_size + 1));

        raft::matrix::fill(handle, offsets.view(), (IdxT)k);

        thrust::exclusive_scan(raft::resource::get_thrust_policy(handle),
                               offsets.data_handle(),
                               offsets.data_handle() + offsets.size(),
                               offsets.data_handle(),
                               0);

        auto keys = raft::make_device_vector_view<T, IdxT>(out_val, (IdxT)(batch_size * k));
        auto vals = raft::make_device_vector_view<IdxT, IdxT>(out_idx, (IdxT)(batch_size * k));

        segmented_sort_by_key<T, IdxT>(
          handle, raft::make_const_mdspan(offsets.view()), keys, vals, select_min);
      }
      return;
    }
    case SelectAlgo::kWarpDistributed:
      return detail::select::warpsort::
        select_k_impl<T, IdxT, detail::select::warpsort::warp_sort_distributed>(
          in_val, in_idx, batch_size, len, k, out_val, out_idx, select_min, stream, mr);
    case SelectAlgo::kWarpDistributedShm:
      return detail::select::warpsort::
        select_k_impl<T, IdxT, detail::select::warpsort::warp_sort_distributed_ext>(
          in_val, in_idx, batch_size, len, k, out_val, out_idx, select_min, stream, mr);
    case SelectAlgo::kWarpAuto:
      return detail::select::warpsort::select_k<T, IdxT>(
        in_val, in_idx, batch_size, len, k, out_val, out_idx, select_min, stream, mr);
    case SelectAlgo::kWarpImmediate:
      return detail::select::warpsort::
        select_k_impl<T, IdxT, detail::select::warpsort::warp_sort_immediate>(
          in_val, in_idx, batch_size, len, k, out_val, out_idx, select_min, stream, mr);
    case SelectAlgo::kWarpFiltered:
      return detail::select::warpsort::
        select_k_impl<T, IdxT, detail::select::warpsort::warp_sort_filtered>(
          in_val, in_idx, batch_size, len, k, out_val, out_idx, select_min, stream, mr);
    default: RAFT_FAIL("K-selection Algorithm not supported.");
  }
}

/**
 * Selects the k smallest or largest keys/values from each row of the input matrix.
 *
 * This function operates on a row-major matrix `in_val` with dimensions `batch_size` x `len`,
 * selecting the k smallest or largest elements from each row. The selected elements are then stored
 * in a row-major output matrix `out_val` with dimensions `batch_size` x k.
 *
 * @tparam T
 *   Type of the elements being compared (keys).
 * @tparam IdxT
 *   Type of the indices associated with the keys.
 * @tparam NZType
 *   Type representing non-zero elements of `in_val`.
 *
 * @param[in] handle
 *   Container for managing reusable resources.
 * @param[in] in_val
 *   Input matrix in CSR format with a logical dense shape of [batch_size, len],
 *   containing the elements to be compared and selected.
 * @param[in] in_idx
 *   Optional input indices [in_val.nnz] associated with `in_val.values`.
 *   If `in_idx` is `std::nullopt`, it defaults to a contiguous array from 0 to len-1.
 * @param[out] out_val
 *   Output matrix [in_val.get_n_row(), k] storing the selected k smallest/largest elements
 *   from each row of `in_val`.
 * @param[out] out_idx
 *   Output indices [in_val.get_n_row(), k] corresponding to the selected elements in `out_val`.
 * @param[in] select_min
 *   Flag indicating whether to select the k smallest (true) or largest (false) elements.
 * @param[in] mr
 *   An optional memory resource to use across the calls (you can provide a large enough
 *           memory pool here to avoid memory allocations within the call).
 */
template <typename T, typename IdxT>
void select_k(raft::resources const& handle,
              raft::device_csr_matrix_view<const T, IdxT, IdxT, IdxT> in_val,
              std::optional<raft::device_vector_view<const IdxT, IdxT>> in_idx,
              raft::device_matrix_view<T, IdxT, raft::row_major> out_val,
              raft::device_matrix_view<IdxT, IdxT, raft::row_major> out_idx,
              bool select_min,
              rmm::mr::device_memory_resource* mr = nullptr)
{
  auto csr_view = in_val.structure_view();
  auto nnz      = csr_view.get_nnz();

  if (nnz == 0) return;

  auto batch_size = csr_view.get_n_rows();
  auto len        = csr_view.get_n_cols();
  auto k          = IdxT(out_val.extent(1));

  if (mr == nullptr) { mr = rmm::mr::get_current_device_resource(); }
  RAFT_EXPECTS(out_val.extent(1) <= int64_t(std::numeric_limits<int>::max()),
               "output k must fit the int type.");

  RAFT_EXPECTS(batch_size == out_val.extent(0), "batch sizes must be equal");
  RAFT_EXPECTS(batch_size == out_idx.extent(0), "batch sizes must be equal");

  if (in_idx.has_value()) {
    RAFT_EXPECTS(size_t(nnz) == in_idx->size(),
                 "nnz of in_val must be equal to the length of in_idx");
  }
  RAFT_EXPECTS(IdxT(k) == out_idx.extent(1), "value and index output lengths must be equal");

  auto stream = raft::resource::get_cuda_stream(handle);

  rmm::device_uvector<IdxT> offsets(batch_size + 1, stream);
  rmm::device_uvector<T> keys(nnz, stream);
  rmm::device_uvector<IdxT> values(nnz, stream);

  raft::copy(offsets.data(), csr_view.get_indptr().data(), batch_size + 1, stream);
  raft::copy(keys.data(), in_val.get_elements().data(), nnz, stream);
  raft::copy(values.data(),
             (in_idx.has_value() ? in_idx->data_handle() : csr_view.get_indices().data()),
             nnz,
             stream);

  segmented_sort_by_key(handle,
                        keys.data(),
                        values.data(),
                        size_t(batch_size),
                        size_t(nnz),
                        offsets.data(),
                        select_min);

  auto src_val      = raft::make_device_vector_view<T, IdxT>(keys.data(), nnz);
  auto offsets_view = raft::make_device_vector_view<IdxT, IdxT>(offsets.data(), batch_size + 1);
  raft::matrix::segmented_copy<T, IdxT>(handle, k, src_val, offsets_view, out_val);

  auto src_idx = raft::make_device_vector_view<IdxT, IdxT>(values.data(), nnz);
  raft::matrix::segmented_copy<IdxT, IdxT>(handle, k, src_idx, offsets_view, out_idx);
}

}  // namespace raft::matrix::detail
