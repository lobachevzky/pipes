#include <stdio.h> 
#include <stdlib.h> 
#include <math.h> 
#include <cuda_runtime.h> 
#include "cublas_v2.h" 
#include "matrix.h" 
#include "scan.h" 

#define UN_MAP(name, f_body) \
  __device__ \
  float f_ ## name(float x) { \
    return f_body; \
  } \
  __global__ \
  void _ ## name(int len, float *result, float *a) { \
    SET(result, f_ ## name(a[IDx])) \
  } \
  void map_ ## name(Matrix *m, Matrix *result) { \
    DEFAULT_LAUNCH(_ ## name, result, m->dev_array); \
  }

#define BIN_BROADCAST(name, op) \
  __global__ \
  void _ ## name ## _scalar(int len, float *result, float *a, float val) { \
    SET(result, val op a[IDx]) \
  } \
  void broadcast_ ## name(float val, Matrix *m, Matrix *result) { \
    DEFAULT_LAUNCH(_ ## name ## _scalar, result, m->dev_array, val); \
  }

#define BIN_BROADCAST_REV(name, op) \
  __global__ \
  void _ ## name ## _scalar_rev(int len, float *result, float *a, float val) { \
    SET(result, a[IDx] op val) \
  } \
  void broadcast_ ## name ## _rev(Matrix *m, float val, Matrix *result) { \
    DEFAULT_LAUNCH(_ ## name ## _scalar_rev, result, m->dev_array, val); \
  }

#define BIN_ELEMWISE(name, op) \
  __global__ \
  void _ ## name (int len, float *result, float *a1, float *a2) { \
    SET(result, a1[IDx] op a2[IDx]) \
  } \
  void elemwise_ ## name (Matrix *m1, Matrix *m2, Matrix *result) { \
    check_dims(m1, m2, result); \
    DEFAULT_LAUNCH(_ ## name, result, m1->dev_array, m2->dev_array); \
  }

void check_dims(Matrix *m1, Matrix *m2, Matrix *result) { 
  check(m1->height != m2->height 
     || m1->width  != m2->width
     || m1->height != result->height 
     || m1->width  != result->width, 
      "matrices must have the same dimensions");
}

extern "C" {
  UN_MAP(neg, -x) // map_neg

  BIN_ELEMWISE(mult, *) // elemwise_mult
  BIN_ELEMWISE(add, +) // elemwise_add
  BIN_ELEMWISE(sub, -) // elemwise_sub

  BIN_BROADCAST(mult, *) // broadcast_mult
  BIN_BROADCAST(add, +) // broadcast_add
  BIN_BROADCAST(sub, -) // broadcast_sub

  BIN_BROADCAST_REV(sub, -) // broadcast_sub_rev

  float reduce_sum(Matrix *m) {
    int size_matrix = size(*m);
    check(size_matrix == 0, "matrix must have more than 0 elements.");

    float return_val [10];
    cudaMemcpy(&return_val, m->dev_array, 6 * sizeof(float),
        cudaMemcpyDeviceToHost);

    int i;
    rng(i, 0, 6) {
      printf("%f ", return_val[i]);
    }
    printf("\n");


    float *dev_idata;
    cudaError_t cudaStat = cudaMalloc((void**)&dev_idata,
        size_matrix*sizeof(*dev_idata));
    check(cudaStat != cudaSuccess, "cudaMalloc failed for `temp` in `reduce_avg`");
    cudaMemcpy(dev_idata, m->dev_array, size_matrix * sizeof(*dev_idata),
        cudaMemcpyDeviceToHost);

    float *dev_temp;
    cudaStat = cudaMalloc((void**)&dev_temp,
        size_matrix*sizeof(*dev_temp));
    check(cudaStat != cudaSuccess, "cudaMalloc failed for `temp` in `reduce_avg`");

    dev_scan(size_matrix, dev_temp, dev_idata);

    cudaMemcpy(&return_val, dev_temp, 6 * sizeof(*dev_idata),
        cudaMemcpyDeviceToHost);

    rng(i, 0, 6) {
      printf("%f ", return_val[i]);
    }
    printf("\n");

    return *return_val;
  }
}
