#ifndef TART_NATIVE_SOURCE_NODE_H
#define TART_NATIVE_SOURCE_NODE_H

#ifdef __OBJC__
#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#include "CTacticalAudioRealtime.h"

#define TART_NATIVE_SOURCE_OK 0u
#define TART_NATIVE_SOURCE_INVALID_INPUT 1u
#define TART_NATIVE_SOURCE_MARKER_ALLOCATION_FAILED 2u
#define TART_NATIVE_SOURCE_BLOCK_ALLOCATION_FAILED 3u
#define TART_NATIVE_SOURCE_NODE_NIL 4u
#define TART_NATIVE_SOURCE_EXCEPTION 5u
#define TART_NATIVE_SOURCE_INJECTED_BEFORE_MARKER 6u

NS_ASSUME_NONNULL_BEGIN

/* Nullable +1 Objective-C return, imported as a managed optional in Swift.
   retirement_owned is independent of the node result. Once true, ONLY final
   native marker deallocation can publish retirement, even on nil/exception.
   Neither factory nor block nor marker owns/frees the C allocation. */
AVAudioSourceNode * _Nullable tart_create_source_node(
    TARTContext * _Nullable context, AVAudioFormat * _Nullable format,
    uint32_t *status, bool *retirement_owned) NS_RETURNS_RETAINED;

/* CPU lifetime fixture only. Creates no node, engine, input, or device graph. */
NSObject * _Nullable tart_create_retirement_marker_for_testing(
    TARTContext * _Nullable context) NS_RETURNS_RETAINED;

#define TART_NATIVE_PROBE_BEFORE_MARKER 1u
#define TART_NATIVE_PROBE_NIL_AFTER_BLOCK_COPY 2u
#define TART_NATIVE_PROBE_EXCEPTION_AFTER_BLOCK_COPY 3u

/* Setup-failure fixture. Retains a native copy of the exact production render
   block to model an SDK initializer that copies then returns nil or throws.
   No AVAudioSourceNode/engine is constructed by this probe. Dropping the final
   managed probe releases that block; it never frees C storage. */
@interface TARTNativeSourceProbe : NSObject
@property(nonatomic, readonly) uint32_t status;
@property(nonatomic, readonly) BOOL retirementOwned;
@end

TARTNativeSourceProbe * _Nullable tart_create_source_probe_for_testing(
    TARTContext * _Nullable context, uint32_t behavior) NS_RETURNS_RETAINED;

NS_ASSUME_NONNULL_END
#endif
#endif
