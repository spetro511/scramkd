#ifndef CTACTICAL_AUDIO_REALTIME_H
#define CTACTICAL_AUDIO_REALTIME_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <CoreAudio/CoreAudioTypes.h>

#define TART_QUEUE_CAPACITY 16u
#define TART_ENABLED 1u
#define TART_MUTED 2u
#define TART_OK 0u
#define TART_FULL 1u
#define TART_INVALID 2u
#define TART_NOT_LOCK_FREE 3u
#define TART_DEVICE_CHANGED 4u
#define TART_STALE 5u
#define TART_ALLOCATION_FAILED 6u
#define TART_SINE 0u
#define TART_SAW 1u
#define TART_SQUARE 2u
#define TART_ABORT_CUE 3u

typedef struct TARTContext TARTContext;
typedef struct {
    double sample_rate;
    uint32_t channels;
    uint32_t maximum_frames;
} TARTConfig;
typedef struct { uint32_t epoch, flags; } TARTControl;
typedef struct {
    uint32_t epoch, sequence, cue_id, flags;
    double frequency_a, frequency_b;
    uint32_t segment_frames, segment_count;
    float peak;
    uint32_t waveform;
    uint32_t attack_frames, release_frames;
    uint32_t total_frames, reserved;
} TARTCommand;
typedef struct {
    float *samples;
    uint32_t capacity_samples, stride;
} TARTPlane;
/* CPU-only split-snapshot regression seam; no hooks execute in a live callback. */
typedef struct {
    uint32_t head, reserved;
    uint64_t urgent, control;
} TARTInputSnapshot;
TARTInputSnapshot tart_capture_input_bounds_for_testing(const TARTContext *context);
TARTInputSnapshot tart_complete_snapshot_for_testing(const TARTContext *context, TARTInputSnapshot bounds);
uint32_t tart_render_snapshot_for_testing(TARTContext *context, uint32_t frames,
    const TARTPlane *planes, uint32_t plane_count, TARTInputSnapshot snapshot);

/* Creation/validation/destruction are control-thread operations only. */
TARTContext *tart_create(TARTConfig config, uint32_t *error);
/* Once, before installing a consumer. Bounded peak normalization runs off-render. */
void tart_prepare_waveforms(TARTContext *context);
bool tart_atomics_are_lock_free(const TARTContext *context);
uint32_t tart_validate_command(const TARTContext *context, const TARTCommand *command);
/* Exactly one serialized producer; never resets consumer-owned indices. */
uint32_t tart_try_enqueue(TARTContext *context, const TARTCommand *command);
void tart_publish_control(TARTContext *context, TARTControl control);
void tart_publish_gain(TARTContext *context, float linear_gain);
void tart_publish_abort(TARTContext *context, uint32_t epoch, uint32_t sequence);
uint64_t tart_load_abort_ack(const TARTContext *context);
/* Single nonconcurrent render consumer. All work is bounded by config and 32 harmonics. */
uint32_t tart_render(TARTContext *context, uint32_t frames,
                     const TARTPlane *planes, uint32_t plane_count);
uint32_t tart_render_audio_buffer_list(TARTContext *context, uint32_t frames,
                                       AudioBufferList *buffers, bool *is_silent);
/* Progress: upper 32 bits epoch, lower 32 bits render-observed cue (zero = idle). */
uint64_t tart_load_progress(const TARTContext *context);
uint64_t tart_load_started_count(const TARTContext *context);
uint32_t tart_load_fault(const TARTContext *context);
/* Device-change fault is terminal for this allocation, independent of producer controls. */
void tart_mark_device_changed(TARTContext *context);
void tart_mark_producer_attached(TARTContext *context);
void tart_mark_producer_detached(TARTContext *context);
/* Final token operation: publish retirement, then perform NO further context access. */
void tart_mark_callback_retired(TARTContext *context);
bool tart_callback_is_retired(const TARTContext *context);
bool tart_is_quiescent(const TARTContext *context);
/* Swift AudioReclamationControl ONLY, after final owning-handle release and quiescence.
   Never called by a callback token, storage deinit, or render thread. */
bool tart_destroy_quiescent(TARTContext *context);
/* CPU regression seam: both endpoints retired and queue empty; never a live-graph operation. */
bool tart_seed_quiescent_indices_for_testing(TARTContext *context, uint32_t index);

#ifdef __OBJC__
#import "TARTNativeSourceNode.h"
#endif

#endif
