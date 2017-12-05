#include "mygpuspec.h"

#include <cufft.h>
#include <cufftXt.h>
#include <helper_cuda.h>

#define NO_PLAN   ((cufftHandle)-1)
#define NO_STREAM ((cudaStream_t)-1)

#define PRINT_ERRMSG(error)                  \
  fprintf(stderr, "got error %s at %s:%d\n", \
      _cudaGetErrorEnum(error),  \
      __FILE__, __LINE__)

// CPU context structure
typedef struct {
  // Device pointer to FFT input buffer
  char2 * d_fft_in;
  // Array of device pointers to FFT output buffers
  cufftComplex * d_fft_out[MAX_OUTPUTS];
  // Array of device pointers to power buffers
  float * d_pwr_out[MAX_OUTPUTS];
  // Array of handles to FFT plans
  cufftHandle plan[MAX_OUTPUTS];
  // Array of Ns values (number of specta (FFTs) per input buffer for Nt)
  unsigned int Nss[MAX_OUTPUTS];
  // Array of cudaStream_t values
  cudaStream_t stream[MAX_OUTPUTS];
  // Array of `na` values.  `na` is the number of accumulated spectra thus far
  // for a given output product.  Not to be confused with `Na`, the number of
  // spectra to accumulate for a given output product.
  unsigned int nas[MAX_OUTPUTS];
} mygpuspec_gpu_context;

// Texture declarations
texture<char, 2, cudaReadModeNormalizedFloat> char_tex;

__device__ cufftComplex load_callback(void *p_v_in,
                                      size_t offset,
                                      void *p_v_user,
                                      void *p_v_shared)
{
  cufftComplex c;
  offset += (cufftComplex *)p_v_in - (cufftComplex *)p_v_user;
  c.x = tex2D(char_tex, ((2*offset  ) & 0x7fff), ((  offset  ) >> 14));
  c.y = tex2D(char_tex, ((2*offset+1) & 0x7fff), ((2*offset+1) >> 15));
  return c;
}

__device__ void store_callback(void *p_v_out,
                               size_t offset,
                               cufftComplex element,
                               void *p_v_user,
                               void *p_v_shared)
{
  float pwr = element.x * element.x + element.y * element.y;
  ((float *)p_v_user)[offset] = pwr;
}

__device__ void accum_callback(void *p_v_out,
                               size_t offset,
                               cufftComplex element,
                               void *p_v_user,
                               void *p_v_shared)
{
  float pwr = element.x * element.x + element.y * element.y;
  ((float *)p_v_user)[offset] += pwr;
}

__device__ cufftCallbackLoadC d_cufft_load_callback = load_callback;
__device__ cufftCallbackStoreC d_cufft_store_callback = store_callback;
__device__ cufftCallbackStoreC d_cufft_accum_callback = accum_callback;

// TODO Accumulate kernel

#include <time.h> // For nanosleep

// Stream callback function that is called right after an output product's GPU
// power buffer has been copied to the host power buffer.
static void CUDART_CB dump_callback(cudaStream_t stream,
                                    cudaError_t status,
                                    void *data)
{
  struct timespec ts_100ms = {0, 100 * 1000 * 1000};
  printf("Inside callback %ld\n", (long int)data);
  nanosleep(&ts_100ms, NULL);
}

// Sets ctx->Ntmax.
// Allocates host and device buffers based on the ctx->N values.
// Allocates and sets the ctx->mygpuspec_gpu_ctx field.
// Creates CuFFT plans.
// Creates streams.
// Returns 0 on success, non-zero on error.
int mygpuspec_initialize(mygpuspec_context * ctx)
{
  int i;
  size_t inbuf_size;
  unsigned int Nd; // Number of spectra per dump (per output product)
  cudaError_t cuda_rc;
  cufftResult cufft_rc;

  // Host copies of cufft callback pointers
  cufftCallbackLoadC h_cufft_load_callback;
  cufftCallbackStoreC h_cufft_store_callback;
  cufftCallbackStoreC h_cufft_accum_callback;

  // Validate ctx->No
  if(ctx->No == 0 || ctx->No > MAX_OUTPUTS) {
    fprintf(stderr, "output products must be in range [1..%d], not %d\n",
        MAX_OUTPUTS, ctx->No);
    return 1;
  }

  // Validate Ntpb
  if(ctx->Ntpb == 0) {
    fprintf(stderr, "number of time samples per block cannot be zero\n");
    return 1;
  }

  // Determine Ntmax (and validate Nts)
  ctx->Ntmax = 0;
  for(i=0; i<ctx->No; i++) {
    if(ctx->Nts[i] == 0) {
      fprintf(stderr, "Nts[%d] cannot be 0\n", i);
      return 1;
    }
    if(ctx->Ntmax < ctx->Nts[i]) {
      ctx->Ntmax = ctx->Nts[i];
    }
  }
  // Validate that all Nts are factors of Ntmax.  This constraint helps
  // simplify input buffer management.
  for(i=0; i<ctx->No; i++) {
    if(ctx->Ntmax % ctx->Nts[i] != 0) {
      fprintf(stderr, "Nts[%d] (%u) is not a factor of Ntmax (%u)\n",
          i, ctx->Nts[i], ctx->Ntmax);
      return 1;
    }
  }

  // Validate/calculate Nb
  // If ctx->Nb is given by caller (i.e. is non-zero)
  if(ctx->Nb != 0) {
    // Validate that Ntmax is a factor of (Nb * Ntpb)
    if((ctx->Nb * ctx->Ntpb) % ctx->Ntmax != 0) {
      fprintf(stderr,
          "Ntmax (%u) is not a factor of Nb*Ntpb (%u * %u = %u)\n",
          ctx->Ntmax, ctx->Nb, ctx->Ntpb, ctx->Nb*ctx->Ntpb);
      return 1;
    }
  } else {
    // Calculate Nb
    // If Ntmax is less than one block
    if(ctx->Ntmax < ctx->Ntpb) {
      // Validate that Ntmax is a factor of Ntpb
      if(ctx->Ntpb % ctx->Ntmax != 0) {
        fprintf(stderr, "Ntmax (%u) is not a factor of Ntpb (%u)\n",
            ctx->Ntmax, ctx->Ntpb);
        return 1;
      }
      ctx->Nb = 1;
    } else {
      // Validate that Ntpb is factor of Ntmax
      if(ctx->Ntmax % ctx->Ntpb != 0) {
        fprintf(stderr, "Ntpb (%u) is not a factor of Nmax (%u)\n",
            ctx->Ntpb, ctx->Ntmax);
        return 1;
      }
      ctx->Nb = ctx->Ntmax / ctx->Ntpb;
    }
  }

  // Validate Nas
  for(i=0; i < ctx->No; i++) {
    if(ctx->Nas[i] == 0) {
      fprintf(stderr, "Nas[%d] cannot be 0\n", i);
      return 1;
    }
    // If mulitple integrations per input buffer
    if(ctx->Nts[i]*ctx->Nas[i] < ctx->Nb*ctx->Ntpb) {
      // Must have integer integrations per input buffer
      if((ctx->Nb * ctx->Ntpb) % (ctx->Nts[i] * ctx->Nas[i]) != 0) {
        fprintf(stderr,
            "Nts[%d] * Nas[%d] (%u * %u) must divide Nb * Ntpb (%u * %u)\n",
            i, i, ctx->Nts[i], ctx->Nas[i], ctx->Nb, ctx->Ntpb);
        return 1;
      }
    } else {
      // Must have integer input buffers per integration
      if((ctx->Nts[i] * ctx->Nas[i]) % (ctx->Nb * ctx->Ntpb) != 0) {
        fprintf(stderr,
            "Nb * Ntpb (%u * %u) must divide Nts[%d] * Nas[%d] (%u * %u)\n",
            ctx->Nb, ctx->Ntpb, i, i, ctx->Nts[i], ctx->Nas[i]);
        return 1;
      }
    }
  }

  // Null out all pointers
  ctx->h_blkbufs = NULL;
  for(i=0; i < MAX_OUTPUTS; i++) {
    ctx->h_pwrbuf[i] = NULL;
  }
  ctx->gpu_ctx = NULL;

  // Alllocate host input block buffers
  ctx->h_blkbufs = (char **)malloc(ctx->Nb * sizeof(char *));
  for(i=0; i < ctx->Nb; i++) {
    // Block buffer can use write combining
    cuda_rc = cudaHostAlloc(&ctx->h_blkbufs[i],
                       ctx->Ntpb*ctx->Np*ctx->Nc*sizeof(char2),
                       cudaHostAllocWriteCombined);
    if(cuda_rc != cudaSuccess) {
      PRINT_ERRMSG(cuda_rc);
      return 1;
    }
  }

  // Allocate GPU context
  mygpuspec_gpu_context * gpu_ctx = (mygpuspec_gpu_context *)malloc(sizeof(mygpuspec_gpu_context));

  if(!gpu_ctx) {
    mygpuspec_cleanup(ctx);
    return 1;
  }

  // Store pointer to gpu_ctx in ctx
  ctx->gpu_ctx = gpu_ctx;

  // NULL out pointers (and invalidate plans)
  gpu_ctx->d_fft_in = NULL;
  for(i=0; i<MAX_OUTPUTS; i++) {
    gpu_ctx->d_fft_out[i] = NULL;
    gpu_ctx->d_pwr_out[i] = NULL;
    gpu_ctx->plan[i] = NO_PLAN;
    gpu_ctx->stream[i] = NO_STREAM;
    gpu_ctx->nas[i] = 0;
  }

  // Calculate Ns and allocate host power output buffers
  for(i=0; i < ctx->No; i++) {
    // Ns[i] is number of specta (FFTs) per coarse channel for one input buffer
    // for Nt[i] points per spectra.
    gpu_ctx->Nss[i] = (ctx->Nb * ctx->Ntpb) / ctx->Nts[i];

    // Calculate number of spectra to dump at one time.
    Nd = gpu_ctx->Nss[i] / ctx->Nas[i];
    if(Nd == 0) {
      Nd = 1;
    }

    // Host buffer needs to accommodate the number of integrations that will be
    // dumped at one time (Nd).
    cuda_rc = cudaHostAlloc(&ctx->h_pwrbuf[i],
                       Nd*ctx->Nts[i]*ctx->Nc*sizeof(float),
                       cudaHostAllocDefault);

    if(cuda_rc != cudaSuccess) {
      PRINT_ERRMSG(cuda_rc);
      mygpuspec_cleanup(ctx);
      return 1;
    }
  }

  // Allocate buffers

  // FFT input buffer
  // The input buffer is padded to the next multiple of 32KB to facilitate 2D
  // texture lookups by treating the input buffer as a 2D array that is 32KB
  // wide.
  inbuf_size = ctx->Nb*ctx->Ntpb*ctx->Np*ctx->Nc*sizeof(char2);
  if((inbuf_size & 0x7fff) != 0) {
    // Round up to next multiple of 32KB
    inbuf_size = (inbuf_size & ~0x7fff) + 0x8000;
  }

  cuda_rc = cudaMalloc(&gpu_ctx->d_fft_in, inbuf_size);
  if(cuda_rc != cudaSuccess) {
    PRINT_ERRMSG(cuda_rc);
    mygpuspec_cleanup(ctx);
    return 1;
  }

  // Bind texture to device input buffer
  // Width is 32KB, height is inbuf_size/32KB, pitch is 32KB
  cuda_rc = cudaBindTexture2D(NULL, char_tex, gpu_ctx->d_fft_in,
                              1<<15, inbuf_size>>15, 1<<15);
  if(cuda_rc != cudaSuccess) {
    PRINT_ERRMSG(cuda_rc);
    mygpuspec_cleanup(ctx);
    return 1;
  }

  // For each output product
  for(i=0; i < ctx->No; i++) {
    // FFT output buffer
    cuda_rc = cudaMalloc(&gpu_ctx->d_fft_out[i], ctx->Nb*ctx->Ntpb*ctx->Nc*sizeof(cufftComplex));
    if(cuda_rc != cudaSuccess) {
      PRINT_ERRMSG(cuda_rc);
      mygpuspec_cleanup(ctx);
      return 1;
    }
    // Power output buffer
    cuda_rc = cudaMalloc(&gpu_ctx->d_pwr_out[i], ctx->Nb*ctx->Ntpb*ctx->Nc*sizeof(float));
    if(cuda_rc != cudaSuccess) {
      PRINT_ERRMSG(cuda_rc);
      mygpuspec_cleanup(ctx);
      return 1;
    }
    // Clear power output buffer
    cuda_rc = cudaMemset(gpu_ctx->d_pwr_out[i], 0, ctx->Nb*ctx->Ntpb*ctx->Nc*sizeof(float));
    if(cuda_rc != cudaSuccess) {
      PRINT_ERRMSG(cuda_rc);
      mygpuspec_cleanup(ctx);
      return 1;
    }
  }

  // Get host pointers to cufft callbacks
  cuda_rc = cudaMemcpyFromSymbol(&h_cufft_load_callback,
                                 d_cufft_load_callback,
                                 sizeof(h_cufft_load_callback));
  if(cuda_rc != cudaSuccess) {
    PRINT_ERRMSG(cuda_rc);
    mygpuspec_cleanup(ctx);
    return 1;
  }

  cuda_rc = cudaMemcpyFromSymbol(&h_cufft_store_callback,
                                 d_cufft_store_callback,
                                 sizeof(h_cufft_store_callback));
  if(cuda_rc != cudaSuccess) {
    PRINT_ERRMSG(cuda_rc);
    mygpuspec_cleanup(ctx);
    return 1;
  }

  cuda_rc = cudaMemcpyFromSymbol(&h_cufft_accum_callback,
                                 d_cufft_accum_callback,
                                 sizeof(h_cufft_accum_callback));
  if(cuda_rc != cudaSuccess) {
    PRINT_ERRMSG(cuda_rc);
    mygpuspec_cleanup(ctx);
    return 1;
  }

  // Generate FFT plans and associate callbacks
  for(i=0; i < ctx->No; i++) {
    // Make the plan
    cufft_rc = cufftPlanMany(&gpu_ctx->plan[i],      // *plan handle
                             1,                      // rank
                             (int *)&ctx->Nts[i],    // *n
                             (int *)&ctx->Nts[i],    // *inembed (unused for 1d)
                             ctx->Np,                // istride
                             ctx->Nts[i]*ctx->Np,    // idist
                             (int *)&ctx->Nts[i],    // *onembed (unused for 1d)
                             1,                      // ostride
                             ctx->Nts[i],            // odist
                             CUFFT_C2C,              // type
                             gpu_ctx->Nss[i]*ctx->Nc // batch
                            );

    if(cufft_rc != CUFFT_SUCCESS) {
      PRINT_ERRMSG(cufft_rc);
      mygpuspec_cleanup(ctx);
      return 1;
    }

    // Now associate the callbacks with the plan.
    cufft_rc = cufftXtSetCallback(gpu_ctx->plan[i],
                                  (void **)&h_cufft_load_callback,
                                  CUFFT_CB_LD_COMPLEX,
                                  (void **)&gpu_ctx->d_fft_in);
    if(cufft_rc != CUFFT_SUCCESS) {
      PRINT_ERRMSG(cufft_rc);
      mygpuspec_cleanup(ctx);
      return 1;
    }

    // If mulitple or exactly one integration per input buffer,
    // no need to integrate over multiple input buffers.
    if(ctx->Nts[i]*ctx->Nas[i] <= ctx->Nb*ctx->Ntpb) {
      // Use the "store" callback
      cufft_rc = cufftXtSetCallback(gpu_ctx->plan[i],
                                    (void **)&h_cufft_store_callback,
                                    CUFFT_CB_ST_COMPLEX,
                                    (void **)&gpu_ctx->d_pwr_out[i]);
    } else { // Multiple input buffers per integration
      // Use the "accum" callback
      cufft_rc = cufftXtSetCallback(gpu_ctx->plan[i],
                                    (void **)&h_cufft_accum_callback,
                                    CUFFT_CB_ST_COMPLEX,
                                    (void **)&gpu_ctx->d_pwr_out[i]);
    }
    if(cufft_rc != CUFFT_SUCCESS) {
      PRINT_ERRMSG(cufft_rc);
      mygpuspec_cleanup(ctx);
      return 1;
    }
  }

  // Create streams and associate with plans
  for(i=0; i < ctx->No; i++) {
    cuda_rc = cudaStreamCreateWithFlags(&gpu_ctx->stream[i], cudaStreamNonBlocking);
    if(cuda_rc != cudaSuccess) {
      PRINT_ERRMSG(cuda_rc);
      mygpuspec_cleanup(ctx);
      return 1;
    }

    cufft_rc = cufftSetStream(gpu_ctx->plan[i], gpu_ctx->stream[i]);
    if(cufft_rc != CUFFT_SUCCESS) {
      PRINT_ERRMSG(cufft_rc);
      mygpuspec_cleanup(ctx);
      return 1;
    }
  }

  return 0;
}

// Frees host and device buffers based on the ctx->N values.
// Frees and sets the ctx->mygpuspec_gpu_ctx field.
// Destroys CuFFT plans.
// Destroys streams.
void mygpuspec_cleanup(mygpuspec_context * ctx)
{
  int i;
  mygpuspec_gpu_context * gpu_ctx;

  if(ctx->h_blkbufs) {
    for(i=0; i < ctx->Nb; i++) {
      cudaFreeHost(ctx->h_blkbufs[i]);
    }
    free(ctx->h_blkbufs);
    ctx->h_blkbufs = NULL;
  }

  for(i=0; i<MAX_OUTPUTS; i++) {
    if(ctx->h_pwrbuf[i]) {
      cudaFreeHost(ctx->h_pwrbuf[i]);
      ctx->h_pwrbuf[i] = NULL;
    }
  }

  if(ctx->gpu_ctx) {
    gpu_ctx = (mygpuspec_gpu_context *)ctx->gpu_ctx;

    if(gpu_ctx->d_fft_in) {
      cudaFree(gpu_ctx->d_fft_in);
    }

    for(i=0; i<MAX_OUTPUTS; i++) {
      if(gpu_ctx->d_fft_out[i]) {
        cudaFree(gpu_ctx->d_fft_out[i]);
      }
      if(gpu_ctx->d_pwr_out[i]) {
        cudaFree(gpu_ctx->d_pwr_out[i]);
      }
      if(gpu_ctx->plan[i] != NO_PLAN) {
        cufftDestroy(gpu_ctx->plan[i]);
      }
      if(gpu_ctx->stream[i] != NO_STREAM) {
        cudaStreamDestroy(gpu_ctx->stream[i]);
      }
    }

    free(ctx->gpu_ctx);
    ctx->gpu_ctx = NULL;
  }
}

// Copy `ctx->h_blkbufs` to GPU input buffer.
// Returns 0 on success, non-zero on error.
int mygpuspec_copy_blocks_to_gpu(mygpuspec_context * ctx)
{
  int b;
  cudaError_t rc;
  mygpuspec_gpu_context * gpu_ctx = (mygpuspec_gpu_context *)ctx->gpu_ctx;

  // TODO Store in GPU context?
  size_t width = ctx->Ntpb * ctx->Np * sizeof(char2);

  for(b=0; b < ctx->Nb; b++) {
    rc = cudaMemcpy2D(gpu_ctx->d_fft_in + b * width / sizeof(char2),
                      ctx->Nb * width,   // dpitch
                      ctx->h_blkbufs[b], // *src
                      width,             // spitch
                      width,             // width
                      ctx->Nc,           // height
                      cudaMemcpyHostToDevice);

    if(rc != cudaSuccess) {
      PRINT_ERRMSG(rc);
      return 1;
    }
  }

  return 0;
}

// Launches FFTs of data in input buffer.  Whenever an output product
// integration is complete, the power spectrum is copied to the host power
// output buffer and the user provided callback, if any, is called.  This
// function returns zero on success or non-zero if an error is encountered.
//
// Processing occurs asynchronously.  Use `mygpuspec_check_for_completion` to
// see how many output products have completed or
// `mygpuspec_wait_for_completion` to wait for all output products to be
// complete.  New data should NOT be copied to the GPU until
// `mygpuspec_check_for_completion` returns `ctx->No` or
// `mygpuspec_wait_for_completion` returns 0.
int mygpuspec_start_processing(mygpuspec_context * ctx)
{
  int i;
  int a;
  int s;
  int p;
  int Na;
  cufftHandle plan;
  cudaStream_t stream;
  cudaError_t cuda_rc;
  cufftResult cufft_rc;
  mygpuspec_gpu_context * gpu_ctx = (mygpuspec_gpu_context *)ctx->gpu_ctx;

  // For each output product
  for(i=0; i < ctx->No; i++) {
    // Get plan and stream
    plan   = gpu_ctx->plan[i];
    stream = gpu_ctx->stream[i];

    // Get number of spectra accumulated thus far from previous input buffers.
    a = gpu_ctx->nas[i];

    // Get number of spectra to accumulate per dump
    Na = ctx->Nas[i];

      // For each polarization
      for(p=0; p < ctx->Np; p++) {
        // Add FFT to stream
        cufft_rc = cufftExecC2C(plan,
                                ((cufftComplex *)gpu_ctx->d_fft_in) + p,
                                gpu_ctx->d_fft_out[i],
                                CUFFT_FORWARD);

        if(cufft_rc != CUFFT_SUCCESS) {
          PRINT_ERRMSG(cufft_rc);
          return 1;
        }
      }

#if 0
      // If integration is complete.  Note that `a` should "never" be greater
      // than `Na`, but we use ">=" in an attempt to be more robust to bugs.
      if(++a >= Na) {
        // Copy data to host power buffer.  This is done is two 2D copies to
        // get channel 0 in the center of the spectrum.  Special care is taken
        // in the unlikely event that Nt is odd.
        cuda_rc = cudaMemcpy2DAsync(ctx->h_pwrbuf[i] + ctx->Nts[i]/2,  // *dst
                                    ctx->Nts[i] * sizeof(float),       // dpitch
                                    gpu_ctx->d_pwr_out[i],             // *src
                                    ctx->Nts[i] * sizeof(float),       // spitch
                                    (ctx->Nts[i]+1)/2 * sizeof(float), // width
                                    ctx->Nc,                           // height
                                    cudaMemcpyDeviceToHost,
                                    stream);

        if(cuda_rc != cudaSuccess) {
          PRINT_ERRMSG(cuda_rc);
          mygpuspec_cleanup(ctx);
          return 1;
        }

        cuda_rc = cudaMemcpy2DAsync(ctx->h_pwrbuf[i],                          // *dst
                                    ctx->Nts[i] * sizeof(float),               // dpitch
                                    gpu_ctx->d_pwr_out[i] + (ctx->Nts[i]+1)/2, // *src
                                    ctx->Nts[i] * sizeof(float),               // spitch
                                    ctx->Nts[i]/2 * sizeof(float),             // width
                                    ctx->Nc,                                   // height
                                    cudaMemcpyDeviceToHost,
                                    stream);

        if(cuda_rc != cudaSuccess) {
          PRINT_ERRMSG(cuda_rc);
          mygpuspec_cleanup(ctx);
          return 1;
        }

        // Add stream callback
        cuda_rc = cudaStreamAddCallback(stream, dump_callback,
                                        (void *)(long int)i, 0);

        if(cuda_rc != cudaSuccess) {
          PRINT_ERRMSG(cuda_rc);
          return 1;
        }

        // Add power buffer clearing cudaMemset call to stream
        cuda_rc = cudaMemsetAsync(gpu_ctx->d_pwr_out[i], 0,
                                  ctx->Nts[i]*ctx->Nc*sizeof(float),
                                  stream);

        if(cuda_rc != cudaSuccess) {
          PRINT_ERRMSG(cuda_rc);
          return 1;
        }

        // Reinitialize a
        a = 0;
      } // if integration is complete

    // Save current value of a
    gpu_ctx->nas[i] = a;
#endif
  } // For each output product

  return 0;
}

// Returns the number of output products that are complete for the current
// input buffer.  More precisely, it returns the number of output products that
// are no longer processing (or never were processing) the input buffer.
unsigned int mygpuspec_check_for_completion(mygpuspec_context * ctx)
{
  int i;
  int num_complete = 0;
  cudaError_t rc;
  mygpuspec_gpu_context * gpu_ctx = (mygpuspec_gpu_context *)ctx->gpu_ctx;

  for(i=0; i<ctx->No; i++) {
    rc = cudaStreamQuery(gpu_ctx->stream[i]);
    if(rc == cudaSuccess) {
      num_complete++;
    }
  }

  return num_complete;
}

// Waits for any pending output products to be compete processing the current
// input buffer.  Returns zero when complete, non-zero on error.
int mygpuspec_wait_for_completion(mygpuspec_context * ctx)
{
  int i;
  cudaError_t rc;
  mygpuspec_gpu_context * gpu_ctx = (mygpuspec_gpu_context *)ctx->gpu_ctx;

  for(i=0; i < ctx->No; i++) {
    rc = cudaStreamSynchronize(gpu_ctx->stream[i]);
    if(rc != cudaSuccess) {
      return 1;
    }
  }

  return 0;
}
