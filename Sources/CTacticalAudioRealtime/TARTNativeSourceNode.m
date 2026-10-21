#import "TARTNativeSourceNode.h"
#include <Block.h>

#if __has_feature(objc_arc)
#error TARTNativeSourceNode_requires_explicit_MRC_compilation
#endif

/* This marker owns ONLY a non-owning C pointer. A copied native block owns the
   marker through ordinary MRC block copy/dispose, never through invoke-time ARC. */
@interface TARTNativeRetirementMarker : NSObject {
@public
    TARTContext *_context;
}
@end

@implementation TARTNativeRetirementMarker
- (void)dealloc {
    TARTContext *context = _context;
    if (context) tart_mark_callback_retired(context);
    /* The release store above is the final context access. NSObject teardown
       below touches only the marker, not C storage or any Swift/control owner. */
    [super dealloc];
}
@end

@interface TARTNativeSourceProbe () {
@public
    uint32_t _status;
    BOOL _retirementOwned;
    AVAudioSourceNodeRenderBlock _heldBlock;
}
@end

@implementation TARTNativeSourceProbe
- (uint32_t)status { return _status; }
- (BOOL)retirementOwned { return _retirementOwned; }
- (void)dealloc {
    if (_heldBlock) Block_release(_heldBlock);
    [super dealloc];
}
@end

static AVAudioSourceNode *TARTBuildSource(
    TARTContext *context, AVAudioFormat *format, uint32_t *status,
    bool *retirement_owned, TARTNativeSourceProbe *probe, uint32_t behavior
) NS_RETURNS_RETAINED;

static AVAudioSourceNode *TARTBuildSource(
    TARTContext *context, AVAudioFormat *format, uint32_t *status,
    bool *retirement_owned, TARTNativeSourceProbe *probe, uint32_t behavior
) {
    if (!status || !retirement_owned) return nil;
    *status = TART_NATIVE_SOURCE_INVALID_INPUT;
    *retirement_owned = false;
    if (!context || (!probe && !format)) return nil;
    if (probe && behavior == TART_NATIVE_PROBE_BEFORE_MARKER) {
        *status = TART_NATIVE_SOURCE_INJECTED_BEFORE_MARKER;
        return nil;
    }
    if (probe && behavior != TART_NATIVE_PROBE_NIL_AFTER_BLOCK_COPY
        && behavior != TART_NATIVE_PROBE_EXCEPTION_AFTER_BLOCK_COPY) return nil;

    TARTNativeRetirementMarker *marker = nil;
    AVAudioSourceNodeRenderBlock callback = nil;
    AVAudioSourceNode *node = nil;
    /* Pool/exception handling is setup-only, never inside the render block. Nil
       allocation results are reported; this is not general OOM recovery. */
    @autoreleasepool {
        @try {
            marker = [[TARTNativeRetirementMarker alloc] init];
            if (!marker) {
                *status = TART_NATIVE_SOURCE_MARKER_ALLOCATION_FAILED;
            } else {
                /* No throwing operation lies between admission and pointer store.
                   From here on, nil node results MUST NOT authorize fake retirement. */
                *retirement_owned = true;
                marker->_context = context;
                callback = Block_copy(^OSStatus(BOOL *isSilence, const AudioTimeStamp *timestamp,
                                                AVAudioFrameCount frames, AudioBufferList *buffers) {
                    (void)timestamp;
                    /* Audit this block's INVOKE, not its copy/dispose helpers.
                       MRC: direct ivar load; C call; scalar result mapping only. */
                    TARTContext *renderContext = marker->_context;
                    bool silent = false;
                    uint32_t result = tart_render_audio_buffer_list(renderContext, frames, buffers, &silent);
                    *isSilence = silent ? YES : NO;
                    return result == TART_OK ? (OSStatus)0 : (OSStatus)-50;
                });
                if (!callback) {
                    *status = TART_NATIVE_SOURCE_BLOCK_ALLOCATION_FAILED;
                } else if (probe) {
                    probe->_heldBlock = Block_copy(callback);
                    if (!probe->_heldBlock) {
                        *status = TART_NATIVE_SOURCE_BLOCK_ALLOCATION_FAILED;
                    } else if (behavior == TART_NATIVE_PROBE_EXCEPTION_AFTER_BLOCK_COPY) {
                        @throw [NSException exceptionWithName:@"TART_NATIVE_PROBE"
                                                      reason:@"INJECTED_AFTER_NATIVE_BLOCK_COPY" userInfo:nil];
                    } else {
                        *status = TART_NATIVE_SOURCE_NODE_NIL;
                    }
                } else {
                    /* The initializer consumes its allocation reference. Only a
                       returned +1 node is transferred to Swift. SDK-internal block
                       copies surviving a nil/exception keep the marker alive and
                       force bounded control-side quarantine; no rollback is claimed. */
                    node = [[AVAudioSourceNode alloc] initWithFormat:format renderBlock:callback];
                    *status = node ? TART_NATIVE_SOURCE_OK : TART_NATIVE_SOURCE_NODE_NIL;
                }
            }
        } @catch (NSException *exception) {
            (void)exception;
            *status = TART_NATIVE_SOURCE_EXCEPTION;
        } @finally {
            if (callback) Block_release(callback);
            [marker release];
        }
    }
    return node;
}

AVAudioSourceNode *tart_create_source_node(TARTContext *context, AVAudioFormat *format,
                                          uint32_t *status, bool *retirement_owned) {
    return TARTBuildSource(context, format, status, retirement_owned, nil, 0);
}

NSObject *tart_create_retirement_marker_for_testing(TARTContext *context) {
    if (!context) return nil;
    TARTNativeRetirementMarker *marker = nil;
    @autoreleasepool {
        @try {
            marker = [[TARTNativeRetirementMarker alloc] init];
            if (marker) marker->_context = context;
        } @catch (NSException *exception) {
            (void)exception;
            [marker release];
            marker = nil;
        }
    }
    return marker;
}

TARTNativeSourceProbe *tart_create_source_probe_for_testing(TARTContext *context, uint32_t behavior) {
    TARTNativeSourceProbe *probe = nil;
    @autoreleasepool {
        @try {
            probe = [[TARTNativeSourceProbe alloc] init];
            if (probe) {
                bool owned = false;
                uint32_t status = TART_NATIVE_SOURCE_INVALID_INPUT;
                AVAudioSourceNode *unexpected = TARTBuildSource(context, nil, &status, &owned, probe, behavior);
                [unexpected release];
                probe->_status = status;
                probe->_retirementOwned = owned ? YES : NO;
            }
        } @catch (NSException *exception) {
            (void)exception;
            [probe release];
            probe = nil;
        }
    }
    return probe;
}
