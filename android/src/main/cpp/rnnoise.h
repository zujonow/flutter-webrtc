// SPDX-License-Identifier: BSD-3-Clause

#ifndef RNNOISE_H
#define RNNOISE_H

#include <stdio.h>

#define FRAME_SIZE_SHIFT 2

#define FREQ_SIZE (FRAME_SIZE + 1)

#define NB_BANDS 22

#define NB_FEATURES ((NB_BANDS + (3 * NB_DELTA_CEPS)) + 2)

/**
 * A `DenoiseState` processes this many samples at a time.
 */
#define DenoiseState_FRAME_SIZE FRAME_SIZE

typedef struct DenoiseState DenoiseState;

typedef struct RNNModel RNNModel;

#ifdef __cplusplus
extern "C" {
#endif // __cplusplus

/**
 * Return the number of samples processed at time
 *
 * See `rnnoise_process_frame()`
 */
int rnnoise_get_frame_size(void);

/**
 * Return the size of DenoiseState
 *
 * It should be avoided, use directly `rnnoise_create`
 */
int rnnoise_get_size(void);

/**
 * Init a pre-allocated DenoiseState
 *
 * It should be avoided, use directly `rnnoise_create`
 */
int rnnoise_init(DenoiseState *st, RNNModel *model);

/**
 * Create and initialize a DenoseState
 *
 * Use `rnnoise_destroy` to deallocate it
 */
DenoiseState *rnnoise_create(RNNModel *model);

/**
 * Deallocate and destroy a DenoiseState
 *
 * Use it only on pointers returned by `rnnoise_create`.
 */
void rnnoise_destroy(DenoiseState *st);

/**
 * Processes a chunk of samples.
 *
 * It processes `rnnoise_get_frame_size()` samples at time.
 *
 * The current output of `process_frame` depends on the current input, but also on the
 * preceding inputs. Because of this, you might prefer to discard the very first output; it
 * will contain some fade-in artifacts.
 */
float rnnoise_process_frame(DenoiseState *st, float *out, float *input);

/**
 * Load a custom model from a file.
 */
RNNModel *rnnoise_model_from_file(FILE *file);

/**
 * Free a Custom Model
 *
 * See `rnnoise_model_from_file`
 */
void rnnoise_model_free(RNNModel *model);

#ifdef __cplusplus
}  // extern "C"
#endif  // __cplusplus

#endif  /* RNNOISE_H */
