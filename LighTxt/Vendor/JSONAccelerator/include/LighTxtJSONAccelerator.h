#ifndef LIGHTXT_JSON_ACCELERATOR_H
#define LIGHTXT_JSON_ACCELERATOR_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

enum {
    LighTxtJSONAcceleratorSuccess = 0,
    LighTxtJSONAcceleratorInvalidJSON = 1,
    LighTxtJSONAcceleratorCancelled = 2,
    LighTxtJSONAcceleratorInsufficientRecordCapacity = 3,
    LighTxtJSONAcceleratorUnsupportedSize = 4,
    LighTxtJSONAcceleratorInternalError = 5
};

typedef struct {
    int64_t start;
    int64_t end;
    int64_t firstChildStart;
    int64_t childCount;
    int64_t metadata;
} LighTxtJSONContainerRecord;

typedef struct {
    uint32_t status;
    uint32_t reserved;
    uint64_t containerCount;
    uint64_t valueCount;
    uint64_t maximumDepth;
    uint64_t rootChildCount;
    uint64_t recordBuildNanoseconds;
    uint64_t validationNanoseconds;
} LighTxtJSONAcceleratorResult;

/// Return false to cancel. `completedWork` is monotonic over two passes and
/// `totalWork` is exactly twice the source byte count.
typedef bool (*LighTxtJSONAcceleratorProgress)(
    void *context,
    uint64_t completedWork,
    uint64_t totalWork,
    uint64_t containerCount,
    uint64_t valueCount
);

/// Builds fixed 40-byte container records from one padded, resident JSON
/// document. Documents through simdjson's 4 GiB boundary receive a concurrent
/// full simdjson value traversal; larger documents use the exact native 64-bit
/// grammar emitter plus concurrent SIMD UTF-8 validation. Any rejection falls
/// back to the bounded Swift diagnostics parser. `sourceCapacity` must include
/// at least SIMDJSON_PADDING bytes after length.
LighTxtJSONAcceleratorResult LighTxtBuildJSONContainerIndex(
    const uint8_t *source,
    uint64_t sourceLength,
    uint64_t sourceCapacity,
    LighTxtJSONContainerRecord *records,
    uint64_t recordCapacity,
    uint64_t maximumNestingDepth,
    LighTxtJSONAcceleratorProgress progress,
    void *progressContext
);

/// Test seam for the >4 GiB product path. It forces the exact native 64-bit
/// grammar/record emitter plus SIMD UTF-8 validation for a bounded input, so
/// adversarial unit tests do not need a multi-gigabyte allocation.
LighTxtJSONAcceleratorResult LighTxtBuildJSONContainerIndexNative64(
    const uint8_t *source,
    uint64_t sourceLength,
    uint64_t sourceCapacity,
    LighTxtJSONContainerRecord *records,
    uint64_t recordCapacity,
    uint64_t maximumNestingDepth,
    LighTxtJSONAcceleratorProgress progress,
    void *progressContext
);

uint64_t LighTxtJSONAcceleratorMaximumSourceLength(void);
uint64_t LighTxtJSONAcceleratorMaximumSIMDDocumentLength(void);
uint64_t LighTxtJSONAcceleratorRequiredPadding(void);

enum {
    LighTxtCSVScannerSuccess = 0,
    LighTxtCSVScannerCheckpointBufferFull = 1,
    LighTxtCSVScannerInvalidInput = 2
};

/// RFC-4180 lexical state carried across independently read source chunks.
/// All offsets and counts are 64-bit so the scanner never truncates large CSVs.
typedef struct {
    uint64_t completedRecords;
    int64_t recordStart;
    uint64_t checkpointInterval;
    uint8_t inQuotedField;
    uint8_t pendingQuote;
    uint8_t atFieldStart;
    uint8_t pendingCarriageReturn;
    uint8_t checkpointPending;
    uint8_t reserved[3];
} LighTxtCSVScannerState;

typedef struct {
    uint32_t status;
    uint32_t reserved;
    uint64_t processedByteCount;
    uint64_t emittedCheckpointCount;
    LighTxtCSVScannerState state;
} LighTxtCSVScannerResult;

/// Scans one bounded source chunk without retaining it. Sparse checkpoint
/// offsets are emitted only at `state.checkpointInterval` record boundaries.
/// If the output fills, resume at `processedByteCount` with the returned state.
LighTxtCSVScannerResult LighTxtScanCSVChunk(
    const uint8_t *source,
    uint64_t sourceLength,
    int64_t sourceBaseOffset,
    uint8_t delimiter,
    LighTxtCSVScannerState state,
    int64_t *checkpointOffsets,
    uint64_t checkpointCapacity
);

#ifdef __cplusplus
}
#endif

#endif
