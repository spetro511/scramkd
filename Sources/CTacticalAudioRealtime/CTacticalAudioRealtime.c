#include "CTacticalAudioRealtime.h"
#include <float.h>
#include <math.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

_Static_assert(sizeof(TARTConfig) == 16 && _Alignof(TARTConfig) == 8, "config ABI");
_Static_assert(offsetof(TARTConfig, channels) == 8 && offsetof(TARTConfig, maximum_frames) == 12, "config fields ABI");
_Static_assert(sizeof(TARTControl) == 8 && _Alignof(TARTControl) == 4, "control ABI");
_Static_assert(offsetof(TARTControl, flags) == 4, "control flags ABI");
_Static_assert(sizeof(TARTCommand) == 64 && _Alignof(TARTCommand) == 8, "command ABI");
_Static_assert(offsetof(TARTCommand, frequency_a) == 16, "frequency ABI");
_Static_assert(offsetof(TARTCommand, peak) == 40, "peak ABI");
_Static_assert(offsetof(TARTCommand, total_frames) == 56, "duration ABI");
_Static_assert(offsetof(TARTCommand, waveform) == 44 && offsetof(TARTCommand, attack_frames) == 48, "waveform ABI");
_Static_assert(offsetof(TARTCommand, release_frames) == 52 && offsetof(TARTCommand, reserved) == 60, "fade ABI");
_Static_assert(sizeof(TARTPlane) == 16 && _Alignof(TARTPlane) == 8, "plane ABI");
_Static_assert(offsetof(TARTPlane, capacity_samples) == 8 && offsetof(TARTPlane, stride) == 12, "plane fields ABI");
_Static_assert(__atomic_always_lock_free(sizeof(uint32_t), 0), "32-bit atomics required");
_Static_assert(__atomic_always_lock_free(sizeof(uint64_t), 0), "64-bit atomics required");
_Static_assert(sizeof(TARTInputSnapshot) == 24, "snapshot ABI");

typedef struct {
    TARTCommand command;
    double phase;
    uint32_t age;
    bool active;
} TARTVoice;

struct TARTContext {
    TARTConfig config;
    _Atomic(uint32_t) head;
    _Atomic(uint32_t) tail;
    _Atomic(uint64_t) control;
    _Atomic(uint64_t) urgent;
    _Atomic(uint64_t) abort_ack;
    _Atomic(uint64_t) progress;
    _Atomic(uint64_t) started_count;
    _Atomic(uint32_t) gain_bits;
    _Atomic(uint32_t) fault;
    _Atomic(uint32_t) producer_detached;
    _Atomic(uint32_t) callback_retired;
    _Atomic(uint32_t) prepared;
    TARTCommand slots[TART_QUEUE_CAPACITY];
    double normalization[2][32];
    /* The fields below have exactly one owner: the render consumer. */
    TARTVoice current, previous;
    uint32_t epoch, crossfade_age, crossfade_frames;
    uint64_t seen_urgent;
    float gain;
    float gain_start, gain_target;
    uint32_t gain_age;
    uint64_t started;
};

static uint32_t float_bits(float value) {
    uint32_t bits;
    memcpy(&bits, &value, sizeof(bits));
    return bits;
}

static float bits_float(uint32_t bits) {
    float value;
    memcpy(&value, &bits, sizeof(value));
    return value;
}

bool tart_atomics_are_lock_free(const TARTContext *c) {
    return c && atomic_is_lock_free(&c->head) && atomic_is_lock_free(&c->tail)
        && atomic_is_lock_free(&c->control) && atomic_is_lock_free(&c->urgent)
        && atomic_is_lock_free(&c->abort_ack) && atomic_is_lock_free(&c->progress)
        && atomic_is_lock_free(&c->started_count)
        && atomic_is_lock_free(&c->gain_bits) && atomic_is_lock_free(&c->fault)
        && atomic_is_lock_free(&c->producer_detached) && atomic_is_lock_free(&c->callback_retired)
        && atomic_is_lock_free(&c->prepared);
}

TARTContext *tart_create(TARTConfig config, uint32_t *error) {
    if (error) *error = TART_INVALID;
    if (!isfinite(config.sample_rate) || config.sample_rate < 8000 || config.sample_rate > 192000
        || config.channels < 1 || config.channels > 2
        || config.maximum_frames == 0 || config.maximum_frames > 16384) return NULL;
    TARTContext *c = calloc(1, sizeof(*c));
    if (!c) {
        if (error) *error = TART_ALLOCATION_FAILED;
        return NULL;
    }
    c->config = config;
    atomic_init(&c->head, 0);
    atomic_init(&c->tail, 0);
    atomic_init(&c->control, UINT64_C(1) << 32);
    atomic_init(&c->urgent, 0);
    atomic_init(&c->abort_ack, 0);
    atomic_init(&c->progress, UINT64_C(1) << 32);
    atomic_init(&c->started_count, 0);
    atomic_init(&c->gain_bits, float_bits(0.06309573444801933f));
    atomic_init(&c->fault, 0);
    atomic_init(&c->producer_detached, 1);
    atomic_init(&c->callback_retired, 0);
    atomic_init(&c->prepared, 0);
    c->gain = 0.06309573444801933f;
    c->gain_start = c->gain_target = c->gain;
    c->crossfade_frames = (uint32_t)llround(config.sample_rate * 0.005);
    if (!tart_atomics_are_lock_free(c)) {
        if (error) *error = TART_NOT_LOCK_FREE;
        free(c);
        return NULL;
    }
    /* Resolve/touch the math path before device rendering. No graph is accessed here. */
    volatile double warm_input = config.sample_rate / (config.sample_rate + 1.0);
    volatile double warm = sin(warm_input) + ceil(warm_input) + fmin(warm_input, 0.5);
    (void)warm;
    if (error) *error = TART_OK;
    return c;
}

uint32_t tart_validate_command(const TARTContext *c, const TARTCommand *p) {
    if (!c || !p || p->epoch == 0 || p->sequence == 0 || p->cue_id == 0 || p->cue_id > 9
        || p->flags != 0 || p->reserved != 0 || p->waveform > TART_SQUARE
        || !isfinite(p->frequency_a) || !isfinite(p->frequency_b)
        || p->frequency_a <= 20 || p->frequency_b <= 20
        || p->frequency_a >= 20000 || p->frequency_b >= 20000
        || p->frequency_a >= c->config.sample_rate * 0.5
        || p->frequency_b >= c->config.sample_rate * 0.5
        || !isfinite(p->peak) || p->peak < 0 || p->peak > 1
        || p->segment_count == 0 || p->segment_count > 8 || p->segment_frames < 2
        || p->attack_frames < 2 || p->release_frames < 2
        || (uint64_t)p->attack_frames + p->release_frames > p->segment_frames
        || (uint64_t)p->segment_frames * p->segment_count != p->total_frames
        || p->total_frames > c->config.sample_rate * 10.0) return TART_INVALID;
    return TART_OK;
}

uint32_t tart_try_enqueue(TARTContext *c, const TARTCommand *p) {
    if (tart_validate_command(c, p) != TART_OK) return TART_INVALID;
    if ((uint32_t)(atomic_load_explicit(&c->control, memory_order_acquire) >> 32) != p->epoch)
        return TART_STALE;
    uint32_t head = atomic_load_explicit(&c->head, memory_order_relaxed);
    uint32_t tail = atomic_load_explicit(&c->tail, memory_order_acquire);
    if ((uint32_t)(head - tail) >= TART_QUEUE_CAPACITY) return TART_FULL;
    c->slots[head % TART_QUEUE_CAPACITY] = *p;
    atomic_store_explicit(&c->head, head + 1, memory_order_release);
    return TART_OK;
}

void tart_publish_control(TARTContext *c, TARTControl control) {
    if (!c) return;
    atomic_store_explicit(&c->control, ((uint64_t)control.epoch << 32) | control.flags,
                          memory_order_release);
}
void tart_publish_gain(TARTContext *c, float gain) {
    if (c && isfinite(gain) && gain >= 0 && gain <= 1)
        atomic_store_explicit(&c->gain_bits, float_bits(gain), memory_order_release);
}
void tart_publish_abort(TARTContext *c, uint32_t epoch, uint32_t sequence) {
    if (c && epoch && sequence)
        atomic_store_explicit(&c->urgent, ((uint64_t)epoch << 32) | sequence, memory_order_release);
}
uint64_t tart_load_abort_ack(const TARTContext *c) {
    return atomic_load_explicit(&c->abort_ack, memory_order_acquire);
}
uint64_t tart_load_progress(const TARTContext *c) {
    return atomic_load_explicit(&c->progress, memory_order_acquire);
}
uint64_t tart_load_started_count(const TARTContext *c) {
    return atomic_load_explicit(&c->started_count, memory_order_acquire);
}
uint32_t tart_load_fault(const TARTContext *c) {
    return atomic_load_explicit(&c->fault, memory_order_acquire);
}
void tart_mark_device_changed(TARTContext *c) {
    atomic_store_explicit(&c->fault, TART_DEVICE_CHANGED, memory_order_release);
}
void tart_mark_producer_attached(TARTContext *c) {
    atomic_store_explicit(&c->producer_detached, 0, memory_order_release);
}
void tart_mark_producer_detached(TARTContext *c) {
    atomic_store_explicit(&c->producer_detached, 1, memory_order_release);
}
void tart_mark_callback_retired(TARTContext *c) {
    atomic_store_explicit(&c->callback_retired, 1, memory_order_release);
}
bool tart_callback_is_retired(const TARTContext *c) {
    return atomic_load_explicit(&c->callback_retired, memory_order_acquire) != 0;
}
bool tart_is_quiescent(const TARTContext *c) {
    return c && tart_callback_is_retired(c)
        && atomic_load_explicit(&c->producer_detached, memory_order_acquire) != 0;
}
bool tart_destroy_quiescent(TARTContext *c) {
    if (!tart_is_quiescent(c)) return false;
    free(c);
    return true;
}

bool tart_seed_quiescent_indices_for_testing(TARTContext *c, uint32_t index) {
    if (!tart_is_quiescent(c)
        || atomic_load_explicit(&c->head, memory_order_relaxed) != atomic_load_explicit(&c->tail, memory_order_relaxed))
        return false;
    atomic_store_explicit(&c->head, index, memory_order_relaxed);
    atomic_store_explicit(&c->tail, index, memory_order_relaxed);
    return true;
}

static uint32_t priority(uint32_t cue) {
    return cue == 3 ? 4 : cue == 5 ? 3 : cue == 4 ? 2 : 1;
}

static void start_voice(TARTContext *c, const TARTCommand *p) {
    c->previous = c->current;
    c->current = (TARTVoice){ .command = *p, .active = true };
    c->crossfade_age = 0;
    if (c->started != UINT64_MAX) ++c->started;
    atomic_store_explicit(&c->started_count, c->started, memory_order_release);
}

/* Fejer-weighted finite Fourier series. All harmonics are strictly below Nyquist.
   The positive normalized Fejer kernel preserves the source waveform's unit peak
   bound; a small numerical margin covers summation rounding. This is a smoothed
   band-limited saw/square, not a discontinuous naive oscillator. */
static double fourier_wave(double phase, uint32_t harmonics, uint32_t kind) {
    const double tau = 6.283185307179586476925286766559;
    double value = 0;
    for (uint32_t n = 1; n <= harmonics; ++n) {
        if (kind == TART_SQUARE && (n & 1u) == 0) continue;
        double weight = (1.0 - (double)n / (harmonics + 1.0)) / n;
        value += weight * sin(tau * n * phase);
    }
    double scale = kind == TART_SAW ? -0.636619772367581343 : 1.273239544735162686;
    return value * scale / (1.0 + 16.0 * DBL_EPSILON * harmonics);
}

void tart_prepare_waveforms(TARTContext *c) {
    if (!c || atomic_load_explicit(&c->prepared, memory_order_acquire)) return;
    const uint32_t grid = 2048;
    const double tau = 6.283185307179586476925286766559;
    for (uint32_t kind = TART_SAW; kind <= TART_SQUARE; ++kind) {
        for (uint32_t h = 1; h <= 32; ++h) {
            double maximum = 0, second_derivative = 0;
            for (uint32_t i = 0; i < grid; ++i)
                maximum = fmax(maximum, fabs(fourier_wave((double)i / grid, h, kind)));
            for (uint32_t n = 1; n <= h; ++n) {
                if (kind == TART_SQUARE && (n & 1u) == 0) continue;
                second_derivative += n * (1.0 - (double)n / (h + 1.0));
            }
            double scale = kind == TART_SAW ? 0.636619772367581343 : 1.273239544735162686;
            second_derivative *= scale * tau * tau;
            /* At a smooth periodic maximum the first derivative is zero. The
               nearest grid sample is <= 1/(2*grid) away; Taylor's remainder bounds
               the unsampled peak by M2/(8*grid^2). Include a rounding margin. */
            double upper = maximum + second_derivative / (8.0 * grid * grid)
                + 64.0 * DBL_EPSILON * h;
            c->normalization[kind - 1][h - 1] = 1.0 / upper;
        }
    }
    atomic_store_explicit(&c->prepared, 1, memory_order_release);
}

static double waveform(const TARTContext *c, double phase, double frequency, uint32_t kind) {
    if (kind == TART_SINE) return sin(6.283185307179586476925286766559 * phase);
    uint32_t harmonics = (uint32_t)fmin(32.0, ceil(c->config.sample_rate * 0.5 / frequency) - 1.0);
    return fourier_wave(phase, harmonics, kind) * c->normalization[kind - 1][harmonics - 1];
}

static double next_sample(TARTVoice *v, const TARTContext *c) {
    if (!v->active) return 0;
    const TARTCommand *p = &v->command;
    uint32_t position = v->age % p->segment_frames;
    uint32_t segment = v->age / p->segment_frames;
    double frequency = (segment & 1u) ? p->frequency_b : p->frequency_a;
    double envelope = 1;
    if (position < p->attack_frames) envelope = (double)position / (p->attack_frames - 1);
    if (position >= p->segment_frames - p->release_frames)
        envelope = fmin(envelope, (double)(p->segment_frames - 1 - position) / (p->release_frames - 1));
    double sample = waveform(c, v->phase, frequency, p->waveform) * p->peak * envelope;
    v->phase += frequency / c->config.sample_rate;
    if (v->phase >= 1) v->phase -= 1;
    if (++v->age >= p->total_frames) v->active = false;
    return sample;
}

static TARTCommand abort_command(const TARTContext *c, uint32_t epoch, uint32_t sequence) {
    uint32_t frames = (uint32_t)llround(c->config.sample_rate * 0.5);
    uint32_t fade = c->crossfade_frames;
    return (TARTCommand){ .epoch = epoch, .sequence = sequence, .cue_id = 3,
        .frequency_a = 1200, .frequency_b = 1200, .segment_frames = frames, .segment_count = 1,
        .peak = 0.8912509381337456f, .waveform = TART_SAW,
        .attack_frames = fade, .release_frames = fade, .total_frames = frames };
}

static uint32_t render_failure(TARTContext *c) {
    if (c) atomic_store_explicit(&c->fault, TART_INVALID, memory_order_release);
    return TART_INVALID;
}

static TARTInputSnapshot capture_bounds(const TARTContext *c) {
    TARTInputSnapshot snapshot = {0};
    snapshot.head = atomic_load_explicit(&c->head, memory_order_acquire);
    snapshot.urgent = atomic_load_explicit(&c->urgent, memory_order_acquire);
    return snapshot;
}

static uint32_t render_snapshot(TARTContext *c, uint32_t frames, const TARTPlane *planes,
                               uint32_t count, TARTInputSnapshot snapshot) {
    if (!c || frames > c->config.maximum_frames || count != c->config.channels || !planes
        || atomic_load_explicit(&c->prepared, memory_order_acquire) == 0)
        return render_failure(c);
    for (uint32_t ch = 0; ch < count; ++ch) {
        if (!planes[ch].samples || (uintptr_t)planes[ch].samples % _Alignof(float)
            || planes[ch].stride == 0 || planes[ch].stride > 2
            || (frames && (uint64_t)(frames - 1) * planes[ch].stride >= planes[ch].capacity_samples))
            return render_failure(c);
    }
    if (frames == 0) return TART_OK;
    uint64_t urgent = snapshot.urgent;
    uint64_t control = snapshot.control;
    uint32_t epoch = (uint32_t)(control >> 32);
    bool audible = (control & TART_ENABLED) && !(control & TART_MUTED)
        && atomic_load_explicit(&c->fault, memory_order_acquire) == 0;
    bool abort_new = urgent != c->seen_urgent && (uint32_t)(urgent >> 32) == epoch && (uint32_t)urgent != 0;
    bool preserve_abort = audible && abort_new && c->current.active && c->current.command.cue_id == 3;
    if (epoch != c->epoch) {
        if (!preserve_abort && !(audible && abort_new)) c->current.active = false;
        c->previous.active = false;
        c->epoch = epoch;
    }
    if (!audible) c->current.active = c->previous.active = false;
    if (abort_new) {
        c->seen_urgent = urgent;
        if (audible && !preserve_abort) {
            TARTCommand p = abort_command(c, epoch, (uint32_t)urgent);
            start_voice(c, &p);
        }
        atomic_store_explicit(&c->abort_ack, urgent, memory_order_release);
    }
    uint32_t tail = atomic_load_explicit(&c->tail, memory_order_relaxed);
    uint32_t head = snapshot.head;
    if ((uint32_t)(head - tail) > TART_QUEUE_CAPACITY) return render_failure(c);
    TARTCommand selected = {0};
    bool found = false;
    for (uint32_t drained = 0; drained < TART_QUEUE_CAPACITY && tail != head; ++drained) {
        TARTCommand p = c->slots[tail % TART_QUEUE_CAPACITY];
        /* Defensive preservation for an explicitly staged/older snapshot. Epochs
           never wrap in a context. The consumer alone advances tail; no retry. */
        if (p.epoch > epoch && epoch != 0) break;
        ++tail;
        if (audible && p.epoch == epoch && (!found || priority(p.cue_id) >= priority(selected.cue_id))) {
            selected = p;
            found = true;
        }
    }
    atomic_store_explicit(&c->tail, tail, memory_order_release);
    if (found && (!c->current.active || priority(selected.cue_id) >= priority(c->current.command.cue_id))) {
        if (!(c->current.active && c->current.command.cue_id == 3 && selected.cue_id == 3))
            start_voice(c, &selected);
    }
    float target = bits_float(atomic_load_explicit(&c->gain_bits, memory_order_acquire));
    if (target != c->gain_target) {
        c->gain_start = c->gain;
        c->gain_target = target;
        c->gain_age = 0;
    }
    for (uint32_t frame = 0; frame < frames; ++frame) {
        double sample = next_sample(&c->current, c);
        if (c->previous.active && c->crossfade_age < c->crossfade_frames) {
            double mix = (double)c->crossfade_age / (c->crossfade_frames - 1);
            sample = next_sample(&c->previous, c) * (1.0 - mix) + sample * mix;
            if (++c->crossfade_age >= c->crossfade_frames) c->previous.active = false;
        }
        if (c->gain_age < c->crossfade_frames) {
            double t = (double)++c->gain_age / c->crossfade_frames;
            c->gain = (float)(c->gain_start * (1.0 - t) + c->gain_target * t);
        }
        float output = audible ? (float)(sample * c->gain) : 0;
        for (uint32_t ch = 0; ch < count; ++ch) planes[ch].samples[frame * planes[ch].stride] = output;
    }
    uint32_t cue = c->current.active ? c->current.command.cue_id : 0;
    atomic_store_explicit(&c->progress, ((uint64_t)epoch << 32) | cue, memory_order_release);
    return TART_OK;
}

uint32_t tart_render(TARTContext *c, uint32_t frames, const TARTPlane *planes, uint32_t count) {
    if (!c) return TART_INVALID;
    /* Producer publishes control before the queue head / urgent release store.
       Acquiring BOTH input bounds before control means an included command's
       preceding control write happens-before the control load. That load cannot
       read an older value (C11 write-read coherence). A later control cancels old
       work legitimately. Later input publications remain outside this head bound.
       The same proof covers mute/unmute writes within one epoch. */
    TARTInputSnapshot snapshot = capture_bounds(c);
    snapshot.control = atomic_load_explicit(&c->control, memory_order_acquire);
    return render_snapshot(c, frames, planes, count, snapshot);
}

TARTInputSnapshot tart_capture_input_bounds_for_testing(const TARTContext *c) {
    return capture_bounds(c);
}
TARTInputSnapshot tart_complete_snapshot_for_testing(const TARTContext *c, TARTInputSnapshot snapshot) {
    snapshot.control = atomic_load_explicit(&c->control, memory_order_acquire);
    return snapshot;
}
uint32_t tart_render_snapshot_for_testing(TARTContext *c, uint32_t frames,
    const TARTPlane *planes, uint32_t count, TARTInputSnapshot snapshot) {
    return render_snapshot(c, frames, planes, count, snapshot);
}

uint32_t tart_render_audio_buffer_list(TARTContext *c, uint32_t frames, AudioBufferList *buffers, bool *silent) {
    if (silent) *silent = false;
    if (!c || !buffers || buffers->mNumberBuffers != c->config.channels || buffers->mNumberBuffers > 2)
        return render_failure(c);
    TARTPlane planes[2];
    for (uint32_t ch = 0; ch < buffers->mNumberBuffers; ++ch) {
        AudioBuffer *b = &buffers->mBuffers[ch];
        if (b->mNumberChannels != 1 || !b->mData || b->mDataByteSize % sizeof(float)) return render_failure(c);
        planes[ch] = (TARTPlane){ b->mData, (uint32_t)(b->mDataByteSize / sizeof(float)), 1 };
    }
    uint32_t result = tart_render(c, frames, planes, buffers->mNumberBuffers);
    if (result != TART_OK) return result;
    bool zeros = true;
    for (uint32_t frame = 0; frame < frames; ++frame) {
        if (planes[0].samples[frame] != 0) { zeros = false; break; }
    }
    if (silent) *silent = zeros;
    return TART_OK;
}
