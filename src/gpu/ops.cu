#include <stdio.h>
#include <stdlib.h>
#include <math.h>
#include <algorithm>
#include <cuda_runtime.h>
#include "cublas_v2.h"
#include "matrix.h"
#include "util.h"

#define IDx_T ((IDx) % (width)) * (width) + ((IDx) / (width))
#define UN_MAP(name, f_body) \
  __device__ \
  float f_ ## name(float x) { \
    return f_body; \
  } \
  __global__ \
  void _ ## name(int len, float *result, const float *a) { \
    SET(result, f_ ## name(a[IDx])) \
  } \
  void map_ ## name(const Matrix *m, Matrix *result) { \
    DEFAULT_LAUNCH(_ ## name, result, m->array); \
  }

#define BIN_BROADCAST(name, op) \
  __global__ \
  void _ ## name ## _scalar(int len, float *result, const float *a, float val) { \
    SET(result, a[IDx] op val) \
  } \
  void broadcast_ ## name(const Matrix *m, float val, Matrix *result) { \
    DEFAULT_LAUNCH(_ ## name ## _scalar, result, m->array, val); \
  }

#define BIN_BROADCAST_REV(name, op) \
  __global__ \
  void _ ## name ## _scalar_rev(int len, float *result, const float *a, float val) { \
    SET(result, val op a[IDx]) \
  } \
  void broadcast_ ## name ## _rev(float val, const Matrix *m, Matrix *result) { \
    DEFAULT_LAUNCH(_ ## name ## _scalar_rev, result, m->array, val); \
  }

#define BIN_ELEMWISE(name, op) \
  __global__ \
  void _ ## name (int len, float *result, const float *a1, const float *a2) { \
    SET(result, a1[IDx] op a2[IDx]) \
  } \
  void elemwise_ ## name (const Matrix *m1, const Matrix *m2, Matrix *result) { \
    check_all_eq(m1, m2, result); \
    DEFAULT_LAUNCH(_ ## name, result, m1->array, m2->array); \
  }
#define CHECK_EQUAL(side1, side2) \
  check(side1 != side2,  #side1 " must equal " #side2)

void check_all_eq(const Matrix *m1, const Matrix *m2, const Matrix *result) {
  CHECK_EQUAL(m1->height, m2->height);
  CHECK_EQUAL(m1->width, m2->width);
  CHECK_EQUAL(m1->height, result->height);
  CHECK_EQUAL(m1->width, result->width);
}

extern "C" {
  UN_MAP(neg, -x) // map_neg
  UN_MAP(sq, x * x) // map_sq
  UN_MAP(abs, x < 0 ? -x : x) // map_aps
  UN_MAP(signum, x < 0 ? -1 : 1) // map_signum
  UN_MAP(sigmoid, 1.0f / (1.0f + expf(-x))) // map_sigmoid
  UN_MAP(tanh, tanh(x)) // map_tanh
  UN_MAP(one_minus, 1.0f - x) // map_one_minus

  BIN_ELEMWISE(mul, *) // elemwise_mul
  BIN_ELEMWISE(add, +) // elemwise_add
  BIN_ELEMWISE(sub, -) // elemwise_sub

  BIN_BROADCAST(mul, *) // broadcast_mul
  BIN_BROADCAST(add, +) // broadcast_add
  BIN_BROADCAST(sub, -) // broadcast_sub

  BIN_BROADCAST_REV(mul, *) // broadcast_mul_rev 
  BIN_BROADCAST_REV(add, +) // broadcast_add_rev
  BIN_BROADCAST_REV(sub, -) // broadcast_sub_rev

  void gemm(const Matrix *m1, bool trans1,
            const Matrix *m2, bool trans2,
            Matrix *result) {

    if (trans1) {
      CHECK_EQUAL(m1->width, result->height);
      if (trans2) {
        CHECK_EQUAL(m1->height, m2->width);
        CHECK_EQUAL(m2->height, result->width);
      } else {
        CHECK_EQUAL(m1->height, m2->height);
        CHECK_EQUAL(m2->width, result->width);
      }
    } else {
      CHECK_EQUAL(m1->height, result->height);
      if (trans2) {
        CHECK_EQUAL(m1->width, m2->width);
        CHECK_EQUAL(m2->height, result->width);
      } else {
        CHECK_EQUAL(m1->width, m2->height);
        CHECK_EQUAL(m2->width, result->width);
      }
    }

    float alpha = 1;
    float beta = 0;
    cublasStatus_t stat = cublasSgemm(handle,
        trans1 ? CUBLAS_OP_T : CUBLAS_OP_N,
        trans2 ? CUBLAS_OP_T : CUBLAS_OP_N,
        result->height,     // m
        result->width,      // n
        trans1 ? m1->height : m1->width,
        &alpha,             // alpha
        m1->array,      // A
        m1->height,         // lda
        m2->array,      // B
        m2->height,         // ldb
        &beta,              // beta
        result->array,  // C
        result->height);    // ldc
    switch (stat) {
      case CUBLAS_STATUS_NOT_INITIALIZED:
        fprintf(stderr,
            "GEMM failed. Cublas not initialized.\n");
        break;
      case CUBLAS_STATUS_INVALID_VALUE:
        fprintf(stderr,
            "GEMM failed. Invalid value.\n");
        break;
      case CUBLAS_STATUS_ARCH_MISMATCH:
        fprintf(stderr,
            "GEMM failed. The device does not support the operation.\n");
        break;
      case CUBLAS_STATUS_EXECUTION_FAILED:
        fprintf(stderr,
            "GEMM failed. The function failed to launch on the GPU.\n");
        break;
    }
    check(stat != CUBLAS_STATUS_SUCCESS, "gemm failed :(");
  }

#define REDUCE_KERNEL(name, atomic_op, val, ...) \
  __global__ \
  void _reduce_ ## name(int len, const float *a, __VA_ARGS__) { \
    if (IDx >= len) return; \
    atomic_op(address, val); \
  }


REDUCE_KERNEL(equal, atomicAnd, a[IDx] == x, unsigned int *address, float x)
REDUCE_KERNEL(lt, atomicAnd, a[IDx] < x, unsigned int *address, float x)
REDUCE_KERNEL(sum, atomicAdd, a[IDx], float *address)

  bool all_equal(const Matrix *m, float x) {
    unsigned int *dev_bool = safe_cuda_malloc<unsigned int>(1);
    unsigned int t = 1;

    cudaError_t cudaStat = host2device<unsigned int>(1, &t, dev_bool);
    check(cudaStat != cudaSuccess, "host2device failed in reduce_eq");

    /*_reduce_equal<<<blockcount(size(m)), BLOCKSIZE>>>*/
    _reduce_equal<<<4, 16>>>
      (size(m), m->array, dev_bool, x);

    cudaStat = device2host<unsigned int>(1, dev_bool, &t);
    check(cudaStat != cudaSuccess, "device2host failed in reduce_sum");

    cudaFree(dev_bool);
    return t == 1;
  }

  bool all_less_than(const Matrix *m, float x) {
    unsigned int *dev_bool = safe_cuda_malloc<unsigned int>(1);
    unsigned int t = 1;

    cudaError_t cudaStat = host2device<unsigned int>(1, &t, dev_bool);
    check(cudaStat != cudaSuccess, "host2device failed in reduce_eq");

    _reduce_lt<<<blockcount(size(m)), BLOCKSIZE>>>
      (size(m), m->array, dev_bool, x);

    cudaStat = device2host<unsigned int>(1, dev_bool, &t);
    check(cudaStat != cudaSuccess, "device2host failed in reduce_sum");

    cudaFree(dev_bool);
    return t == 1;
  }

  float reduce_sum(const Matrix *m) {
    float *dev_sum = safe_cuda_malloc<float>(1);
    float sum = 0;

    cudaError_t cudaStat = host2device<float>(1, &sum, dev_sum);
    check(cudaStat != cudaSuccess, "host2device failed in reduce_sum");

    _reduce_sum<<<blockcount(size(m)), BLOCKSIZE>>>
      (size(m), m->array, dev_sum);

    cudaStat = device2host<float>(1, dev_sum, &sum);
    check(cudaStat != cudaSuccess, "device2host failed in reduce_sum");

    cudaFree(dev_sum);
    return sum;
  }
}
