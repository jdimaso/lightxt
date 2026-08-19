#include "include/LighTxtJSONAccelerator.h"
#include "simdjson/simdjson.h"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstring>
#include <limits>
#include <mutex>
#include <thread>
#include <vector>

#if defined(__aarch64__)
#include <arm_neon.h>
#elif defined(__SSE2__)
#include <emmintrin.h>
#endif

static_assert(sizeof(LighTxtJSONContainerRecord) == 40, "record size must match Swift");
static_assert(
    alignof(LighTxtJSONContainerRecord) == alignof(int64_t),
    "record alignment must match Swift Int64"
);
static_assert(offsetof(LighTxtJSONContainerRecord, start) == 0, "unexpected start offset");
static_assert(offsetof(LighTxtJSONContainerRecord, end) == 8, "unexpected end offset");
static_assert(
    offsetof(LighTxtJSONContainerRecord, firstChildStart) == 16,
    "unexpected firstChildStart offset"
);
static_assert(
    offsetof(LighTxtJSONContainerRecord, childCount) == 24,
    "unexpected childCount offset"
);
static_assert(
    offsetof(LighTxtJSONContainerRecord, metadata) == 32,
    "unexpected metadata offset"
);

namespace {

using simdjson::error_code;

struct ValidationCounts {
    uint64_t values = 0;
    uint64_t containers = 0;
    uint64_t maximumDepth = 0;
};

struct ProgressState {
    const uint8_t *source = nullptr;
    uint64_t length = 0;
    LighTxtJSONAcceleratorProgress callback = nullptr;
    void *context = nullptr;
    uint64_t nextValueCheck = 1u << 20;
    uint64_t buildCompleted = 0;
    uint64_t validationCompleted = 0;
    uint64_t maximumContainers = 0;
    uint64_t maximumValues = 0;
    std::mutex callbackMutex;
    std::atomic<bool> cancelled{false};
    std::atomic<bool> stopRequested{false};

    bool publish(
        uint64_t buildOffset,
        uint64_t validationOffset,
        uint64_t containers,
        uint64_t values
    ) {
        if (stopRequested.load(std::memory_order_relaxed)) return false;
        std::lock_guard<std::mutex> guard(callbackMutex);
        if (stopRequested.load(std::memory_order_relaxed)) return false;
        buildCompleted = std::max(buildCompleted, std::min(length, buildOffset));
        validationCompleted = std::max(
            validationCompleted,
            std::min(length, validationOffset)
        );
        maximumContainers = std::max(maximumContainers, containers);
        maximumValues = std::max(maximumValues, values);
        if (!callback) return true;
        if (!callback(
                context,
                buildCompleted + validationCompleted,
                length * 2,
                maximumContainers,
                maximumValues
            )) {
            cancelled.store(true, std::memory_order_relaxed);
            stopRequested.store(true, std::memory_order_relaxed);
            return false;
        }
        return true;
    }

    bool reportValidation(const char *location, const ValidationCounts &counts) {
        if (stopRequested.load(std::memory_order_relaxed)) return false;
        if (counts.values < nextValueCheck) return true;
        nextValueCheck = counts.values + (1u << 20);
        uint64_t offset = 0;
        if (location && location >= reinterpret_cast<const char *>(source)) {
            offset = std::min<uint64_t>(
                length,
                uint64_t(location - reinterpret_cast<const char *>(source))
            );
        }
        return publish(0, offset, counts.containers, counts.values);
    }

    bool reportBuild(uint64_t offset, uint64_t containers, uint64_t values) {
        return publish(offset, 0, containers, values);
    }

    void requestStop() { stopRequested.store(true, std::memory_order_relaxed); }
};

error_code validateValue(
    simdjson::ondemand::value value,
    uint64_t depth,
    ValidationCounts &counts,
    ProgressState &progress
) {
    counts.values++;
    counts.maximumDepth = std::max(counts.maximumDepth, depth);
    const char *location = nullptr;
    (void)value.current_location().get(location);
    if (!progress.reportValidation(location, counts)) return simdjson::CAPACITY;

    simdjson::ondemand::json_type type;
    SIMDJSON_TRY(value.type().get(type));
    if (type == simdjson::ondemand::json_type::array) {
        counts.containers++;
        simdjson::ondemand::array array;
        SIMDJSON_TRY(value.get_array().get(array));
        for (auto childResult : array) {
            simdjson::ondemand::value child;
            SIMDJSON_TRY(childResult.get(child));
            SIMDJSON_TRY(validateValue(child, depth + 1, counts, progress));
        }
    } else if (type == simdjson::ondemand::json_type::object) {
        counts.containers++;
        simdjson::ondemand::object object;
        SIMDJSON_TRY(value.get_object().get(object));
        for (auto fieldResult : object) {
            SIMDJSON_TRY(fieldResult.error());
            auto field = fieldResult.value_unsafe();
            SIMDJSON_TRY(validateValue(field.value(), depth + 1, counts, progress));
        }
    } else if (type == simdjson::ondemand::json_type::string) {
        std::string_view string;
        SIMDJSON_TRY(value.get_string().get(string));
    } else if (type == simdjson::ondemand::json_type::number) {
        simdjson::ondemand::number number;
        SIMDJSON_TRY(value.get_number().get(number));
    } else if (type == simdjson::ondemand::json_type::boolean) {
        bool boolean = false;
        SIMDJSON_TRY(value.get_bool().get(boolean));
    } else if (type == simdjson::ondemand::json_type::null) {
        bool isNull = false;
        SIMDJSON_TRY(value.is_null().get(isNull));
        if (!isNull) return simdjson::INCORRECT_TYPE;
    }
    return simdjson::SUCCESS;
}

enum class FrameKind : uint8_t { object = 1, array = 2 };
enum class FrameState : uint8_t {
    objectFirstKeyOrEnd,
    objectKey,
    objectColon,
    objectValue,
    objectCommaOrEnd,
    arrayFirstValueOrEnd,
    arrayValue,
    arrayCommaOrEnd
};

struct Frame {
    uint64_t recordOrdinal;
    uint64_t firstChildStart;
    uint64_t pendingKeyStart;
    uint64_t childCount;
    uint64_t depth;
    FrameKind kind;
    FrameState state;
};

inline bool isWhitespace(uint8_t byte) {
    return byte == 0x20 || byte == 0x09 || byte == 0x0a || byte == 0x0d;
}

inline bool containsZeroByte(uint64_t value) {
    constexpr uint64_t ones = 0x0101010101010101ULL;
    constexpr uint64_t highs = 0x8080808080808080ULL;
    return ((value - ones) & ~value & highs) != 0;
}

uint64_t scanString(const uint8_t *source, uint64_t length, uint64_t opening) {
    constexpr uint64_t quotes = 0x2222222222222222ULL;
    constexpr uint64_t slashes = 0x5c5c5c5c5c5c5c5cULL;
    uint64_t cursor = opening + 1;
    while (cursor + sizeof(uint64_t) <= length) {
        uint64_t word;
        std::memcpy(&word, source + cursor, sizeof(word));
        if (containsZeroByte(word ^ quotes) || containsZeroByte(word ^ slashes)) break;
        cursor += sizeof(uint64_t);
    }
    while (cursor < length) {
        if (source[cursor] == 0x22) return cursor + 1;
        if (source[cursor] == 0x5c) {
            cursor += std::min<uint64_t>(2, length - cursor);
        } else {
            cursor++;
        }
    }
    return length;
}

inline bool containsByteLessThanSpace(uint64_t value) {
    constexpr uint64_t spaces = 0x2020202020202020ULL;
    constexpr uint64_t highs = 0x8080808080808080ULL;
    return ((value - spaces) & ~value & highs) != 0;
}

inline bool isHexDigit(uint8_t byte) {
    const uint8_t folded = uint8_t(byte | 0x20);
    return uint8_t(byte - 0x30) <= 9 || uint8_t(folded - 0x61) <= 5;
}

bool scanValidatedString(
    const uint8_t *source,
    uint64_t length,
    uint64_t opening,
    uint64_t &end
) {
    constexpr uint64_t quotes = 0x2222222222222222ULL;
    constexpr uint64_t slashes = 0x5c5c5c5c5c5c5c5cULL;
    uint64_t cursor = opening + 1;
    while (cursor < length) {
        while (cursor + sizeof(uint64_t) <= length) {
            uint64_t word;
            std::memcpy(&word, source + cursor, sizeof(word));
            if (containsZeroByte(word ^ quotes)
                || containsZeroByte(word ^ slashes)
                || containsByteLessThanSpace(word)) {
                break;
            }
            cursor += sizeof(uint64_t);
        }
        if (cursor >= length) return false;
        const uint8_t byte = source[cursor];
        if (byte == 0x22) {
            end = cursor + 1;
            return true;
        }
        if (byte < 0x20) return false;
        if (byte != 0x5c) {
            cursor++;
            continue;
        }
        cursor++;
        if (cursor >= length) return false;
        const uint8_t escape = source[cursor++];
        if (escape == 0x22 || escape == 0x5c || escape == 0x2f
            || escape == 0x62 || escape == 0x66 || escape == 0x6e
            || escape == 0x72 || escape == 0x74) {
            continue;
        }
        if (escape != 0x75) return false;
        if (length - cursor < 4) return false;
        if (!isHexDigit(source[cursor]) || !isHexDigit(source[cursor + 1])
            || !isHexDigit(source[cursor + 2]) || !isHexDigit(source[cursor + 3])) {
            return false;
        }
        cursor += 4;
    }
    return false;
}

inline bool isDigit(uint8_t byte) { return uint8_t(byte - 0x30) <= 9; }

inline bool isEightDigits(const uint8_t *source) {
    uint64_t value;
    std::memcpy(&value, source, sizeof(value));
    return (((value & 0xf0f0f0f0f0f0f0f0ULL)
        | (((value + 0x0606060606060606ULL) & 0xf0f0f0f0f0f0f0f0ULL) >> 4))
        == 0x3333333333333333ULL);
}

void skipDigits(const uint8_t *source, uint64_t length, uint64_t &cursor) {
    while (cursor + 8 <= length && isEightDigits(source + cursor)) cursor += 8;
    while (cursor < length && isDigit(source[cursor])) cursor++;
}

bool scanValidatedNumber(
    const uint8_t *source,
    uint64_t length,
    uint64_t start,
    uint64_t &end
) {
    uint64_t cursor = start;
    if (source[cursor] == 0x2d) {
        cursor++;
        if (cursor >= length) return false;
    }
    if (source[cursor] == 0x30) {
        cursor++;
        if (cursor < length && isDigit(source[cursor])) return false;
    } else {
        if (source[cursor] < 0x31 || source[cursor] > 0x39) return false;
        cursor++;
        skipDigits(source, length, cursor);
    }
    if (cursor < length && source[cursor] == 0x2e) {
        cursor++;
        if (cursor >= length || !isDigit(source[cursor])) return false;
        cursor++;
        skipDigits(source, length, cursor);
    }
    if (cursor < length && (source[cursor] == 0x65 || source[cursor] == 0x45)) {
        cursor++;
        if (cursor < length && (source[cursor] == 0x2b || source[cursor] == 0x2d)) {
            cursor++;
        }
        if (cursor >= length || !isDigit(source[cursor])) return false;
        cursor++;
        skipDigits(source, length, cursor);
    }
    if (cursor < length && !isWhitespace(source[cursor])
        && source[cursor] != 0x2c && source[cursor] != 0x5d
        && source[cursor] != 0x7d) {
        return false;
    }
    end = cursor;
    return true;
}

bool buildSIMDValidatedRecords(
    const uint8_t *source,
    uint64_t length,
    LighTxtJSONContainerRecord *records,
    uint64_t capacity,
    uint64_t maximumNestingDepth,
    ProgressState &progress,
    LighTxtJSONAcceleratorResult &result
) {
    std::vector<Frame> stack;
    stack.reserve(128);
    uint64_t cursor = 0;
    uint64_t containerCount = 0;
    uint64_t valueCount = 0;
    uint64_t rootChildCount = 0;
    uint64_t maximumContainerDepth = 0;
    uint64_t nextProgress = 64u << 20;

    auto acceptValue = [&](uint64_t start) {
        valueCount++;
        if (stack.empty()) {
            rootChildCount++;
            return;
        }
        Frame &parent = stack.back();
        if (parent.childCount == 0) {
            parent.firstChildStart = parent.kind == FrameKind::object
                ? parent.pendingKeyStart
                : start;
        }
        parent.childCount++;
        parent.state = parent.kind == FrameKind::object
            ? FrameState::objectCommaOrEnd
            : FrameState::arrayCommaOrEnd;
    };

    while (cursor < length) {
        if (cursor >= nextProgress) {
            if (!progress.reportBuild(cursor, containerCount, valueCount)) {
                result.status = LighTxtJSONAcceleratorCancelled;
                return false;
            }
            nextProgress = cursor + (64u << 20);
        }
        const uint8_t byte = source[cursor];
        if (isWhitespace(byte)) { cursor++; continue; }
        if (byte == 0x22) {
            const uint64_t end = scanString(source, length, cursor);
            if (!stack.empty() && stack.back().kind == FrameKind::object
                && (stack.back().state == FrameState::objectFirstKeyOrEnd
                    || stack.back().state == FrameState::objectKey)) {
                stack.back().pendingKeyStart = cursor;
                stack.back().state = FrameState::objectColon;
            } else {
                acceptValue(cursor);
            }
            cursor = end;
            continue;
        }
        if (byte == 0x7b || byte == 0x5b) {
            acceptValue(cursor);
            if (stack.size() >= maximumNestingDepth) {
                result.status = LighTxtJSONAcceleratorUnsupportedSize;
                return false;
            }
            if (containerCount >= capacity) {
                result.status = LighTxtJSONAcceleratorInsufficientRecordCapacity;
                return false;
            }
            const uint64_t ordinal = containerCount++;
            const uint64_t depth = stack.size();
            maximumContainerDepth = std::max(maximumContainerDepth, depth);
            auto &record = records[ordinal];
            record.start = int64_t(cursor);
            record.end = int64_t(cursor + 1);
            record.firstChildStart = -1;
            record.childCount = 0;
            record.metadata = int64_t(byte == 0x7b ? 1 : 2) | (int64_t(depth) << 16);
            stack.push_back(Frame{
                ordinal,
                0,
                0,
                0,
                depth,
                byte == 0x7b ? FrameKind::object : FrameKind::array,
                byte == 0x7b
                    ? FrameState::objectFirstKeyOrEnd
                    : FrameState::arrayFirstValueOrEnd
            });
            cursor++;
            continue;
        }
        if (byte == 0x7d || byte == 0x5d) {
            if (stack.empty()) {
                result.status = LighTxtJSONAcceleratorInternalError;
                return false;
            }
            const Frame frame = stack.back();
            stack.pop_back();
            auto &record = records[frame.recordOrdinal];
            record.end = int64_t(cursor + 1);
            record.firstChildStart = frame.childCount == 0
                ? -1
                : int64_t(frame.firstChildStart);
            record.childCount = int64_t(frame.childCount);
            record.metadata |= int64_t(1) << 8;
            cursor++;
            continue;
        }
        if (byte == 0x3a) {
            if (!stack.empty() && stack.back().kind == FrameKind::object) {
                stack.back().state = FrameState::objectValue;
            }
            cursor++;
            continue;
        }
        if (byte == 0x2c) {
            if (!stack.empty()) {
                stack.back().state = stack.back().kind == FrameKind::object
                    ? FrameState::objectKey
                    : FrameState::arrayValue;
            }
            cursor++;
            continue;
        }
        acceptValue(cursor);
        while (cursor < length && !isWhitespace(source[cursor])
               && source[cursor] != 0x2c && source[cursor] != 0x5d
               && source[cursor] != 0x7d) {
            cursor++;
        }
    }

    if (!stack.empty()) {
        result.status = LighTxtJSONAcceleratorInternalError;
        return false;
    }
    if (!progress.reportBuild(length, containerCount, valueCount)) {
        result.status = LighTxtJSONAcceleratorCancelled;
        return false;
    }
    result.status = LighTxtJSONAcceleratorSuccess;
    result.containerCount = containerCount;
    result.valueCount = valueCount;
    result.maximumDepth = maximumContainerDepth;
    result.rootChildCount = rootChildCount;
    return true;
}

bool buildStrictRecords(
    const uint8_t *source,
    uint64_t length,
    LighTxtJSONContainerRecord *records,
    uint64_t capacity,
    uint64_t maximumNestingDepth,
    ProgressState &progress,
    LighTxtJSONAcceleratorResult &result
) {
    std::vector<Frame> stack;
    stack.reserve(128);
    uint64_t cursor = 0;
    uint64_t containerCount = 0;
    uint64_t valueCount = 0;
    uint64_t rootChildCount = 0;
    uint64_t maximumContainerDepth = 0;
    uint64_t nextProgress = 64u << 20;

    bool rootSeen = false;

    auto invalid = [&]() {
        result.status = LighTxtJSONAcceleratorInvalidJSON;
        return false;
    };

    auto acceptValue = [&](uint64_t start) -> bool {
        if (stack.empty()) {
            if (rootSeen) return false;
            rootSeen = true;
            rootChildCount = 1;
            valueCount++;
            return true;
        }
        Frame &parent = stack.back();
        const bool accepts = parent.kind == FrameKind::object
            ? parent.state == FrameState::objectValue
            : parent.state == FrameState::arrayFirstValueOrEnd
                || parent.state == FrameState::arrayValue;
        if (!accepts) return false;
        valueCount++;
        if (parent.childCount == 0) {
            parent.firstChildStart = parent.kind == FrameKind::object
                ? parent.pendingKeyStart
                : start;
        }
        parent.childCount++;
        parent.state = parent.kind == FrameKind::object
            ? FrameState::objectCommaOrEnd
            : FrameState::arrayCommaOrEnd;
        return true;
    };

    while (cursor < length) {
        if (cursor >= nextProgress) {
            if (!progress.reportBuild(cursor, containerCount, valueCount)) {
                result.status = LighTxtJSONAcceleratorCancelled;
                return false;
            }
            nextProgress = cursor + (64u << 20);
        }
        const uint8_t byte = source[cursor];
        if (isWhitespace(byte)) { cursor++; continue; }

        if (byte == 0x22) {
            uint64_t end = cursor;
            if (!scanValidatedString(source, length, cursor, end)) return invalid();
            if (!stack.empty() && stack.back().kind == FrameKind::object
                && (stack.back().state == FrameState::objectFirstKeyOrEnd
                    || stack.back().state == FrameState::objectKey)) {
                stack.back().pendingKeyStart = cursor;
                stack.back().state = FrameState::objectColon;
            } else if (!acceptValue(cursor)) {
                return invalid();
            }
            cursor = end;
            continue;
        }

        if (byte == 0x7b || byte == 0x5b) {
            if (!acceptValue(cursor)) return invalid();
            if (stack.size() >= maximumNestingDepth) {
                result.status = LighTxtJSONAcceleratorUnsupportedSize;
                return false;
            }
            if (containerCount >= capacity) {
                result.status = LighTxtJSONAcceleratorInsufficientRecordCapacity;
                return false;
            }
            const uint64_t ordinal = containerCount++;
            const uint64_t depth = stack.size();
            maximumContainerDepth = std::max(maximumContainerDepth, depth);
            auto &record = records[ordinal];
            record.start = int64_t(cursor);
            record.end = int64_t(cursor + 1);
            record.firstChildStart = -1;
            record.childCount = 0;
            record.metadata = int64_t(byte == 0x7b ? 1 : 2) | (int64_t(depth) << 16);
            stack.push_back(Frame{
                ordinal,
                0,
                0,
                0,
                depth,
                byte == 0x7b ? FrameKind::object : FrameKind::array,
                byte == 0x7b
                    ? FrameState::objectFirstKeyOrEnd
                    : FrameState::arrayFirstValueOrEnd
            });
            cursor++;
            continue;
        }

        if (byte == 0x7d || byte == 0x5d) {
            if (stack.empty()) return invalid();
            const Frame frame = stack.back();
            const bool matchingKind = byte == 0x7d
                ? frame.kind == FrameKind::object
                : frame.kind == FrameKind::array;
            const bool mayClose = frame.kind == FrameKind::object
                ? frame.state == FrameState::objectFirstKeyOrEnd
                    || frame.state == FrameState::objectCommaOrEnd
                : frame.state == FrameState::arrayFirstValueOrEnd
                    || frame.state == FrameState::arrayCommaOrEnd;
            if (!matchingKind || !mayClose) return invalid();
            stack.pop_back();
            auto &record = records[frame.recordOrdinal];
            record.end = int64_t(cursor + 1);
            record.firstChildStart = frame.childCount == 0 ? -1 : int64_t(frame.firstChildStart);
            record.childCount = int64_t(frame.childCount);
            record.metadata |= int64_t(1) << 8;
            cursor++;
            continue;
        }

        if (byte == 0x3a) {
            if (stack.empty() || stack.back().kind != FrameKind::object
                || stack.back().state != FrameState::objectColon) return invalid();
            stack.back().state = FrameState::objectValue;
            cursor++;
            continue;
        }
        if (byte == 0x2c) {
            if (stack.empty() || (stack.back().kind == FrameKind::object
                    ? stack.back().state != FrameState::objectCommaOrEnd
                    : stack.back().state != FrameState::arrayCommaOrEnd)) return invalid();
            stack.back().state = stack.back().kind == FrameKind::object
                ? FrameState::objectKey
                : FrameState::arrayValue;
            cursor++;
            continue;
        }

        if (!acceptValue(cursor)) return invalid();
        if (byte == 0x74 && length - cursor >= 4
            && std::memcmp(source + cursor, "true", 4) == 0) {
            cursor += 4;
        } else if (byte == 0x66 && length - cursor >= 5
            && std::memcmp(source + cursor, "false", 5) == 0) {
            cursor += 5;
        } else if (byte == 0x6e && length - cursor >= 4
            && std::memcmp(source + cursor, "null", 4) == 0) {
            cursor += 4;
        } else if (byte == 0x2d || isDigit(byte)) {
            uint64_t end = cursor;
            if (!scanValidatedNumber(source, length, cursor, end)) return invalid();
            cursor = end;
        } else {
            return invalid();
        }
    }

    if (!stack.empty() || !rootSeen) return invalid();
    if (!progress.reportBuild(length, containerCount, valueCount)) {
        result.status = LighTxtJSONAcceleratorCancelled;
        return false;
    }
    result.status = LighTxtJSONAcceleratorSuccess;
    result.containerCount = containerCount;
    result.valueCount = valueCount;
    result.maximumDepth = maximumContainerDepth;
    result.rootChildCount = rootChildCount;
    return true;
}

} // namespace

extern "C" uint64_t LighTxtJSONAcceleratorMaximumSourceLength(void) {
    const uint64_t addressable = uint64_t((std::numeric_limits<size_t>::max)());
    const uint64_t signedOffsets = uint64_t((std::numeric_limits<int64_t>::max)());
    return std::min(addressable, signedOffsets) - uint64_t(simdjson::SIMDJSON_PADDING);
}

extern "C" uint64_t LighTxtJSONAcceleratorMaximumSIMDDocumentLength(void) {
    return uint64_t(simdjson::SIMDJSON_MAXSIZE_BYTES);
}

extern "C" uint64_t LighTxtJSONAcceleratorRequiredPadding(void) {
    return uint64_t(simdjson::SIMDJSON_PADDING);
}

namespace {

uint64_t scanUntilByte(
    const uint8_t *source,
    uint64_t cursor,
    uint64_t length,
    uint8_t target
) {
    const uint64_t repeated = uint64_t(target) * 0x0101010101010101ULL;
    while (cursor + sizeof(uint64_t) <= length) {
        uint64_t word;
        std::memcpy(&word, source + cursor, sizeof(word));
        if (containsZeroByte(word ^ repeated)) break;
        cursor += sizeof(uint64_t);
    }
    while (cursor < length && source[cursor] != target) cursor++;
    return cursor;
}

struct CSVUnquotedScanResult {
    uint64_t cursor;
    bool atFieldStart;
};

struct CSVByteMasks16 {
    uint16_t delimiters;
    uint16_t quotes;
    uint16_t carriageReturns;
    uint16_t lineFeeds;
};

CSVByteMasks16 classifyCSVBytes16(const uint8_t *source, uint8_t delimiter) {
#if defined(__aarch64__)
    const uint8x16_t bytes = vld1q_u8(source);
    const uint8x16_t weights = {
        1, 2, 4, 8, 16, 32, 64, 128,
        1, 2, 4, 8, 16, 32, 64, 128
    };
    auto comparisonMask = [&](uint8x16_t comparison) -> uint16_t {
        const uint8x16_t weighted = vandq_u8(comparison, weights);
        return uint16_t(vaddv_u8(vget_low_u8(weighted)))
            | (uint16_t(vaddv_u8(vget_high_u8(weighted))) << 8);
    };
    return {
        comparisonMask(vceqq_u8(bytes, vdupq_n_u8(delimiter))),
        comparisonMask(vceqq_u8(bytes, vdupq_n_u8(0x22))),
        comparisonMask(vceqq_u8(bytes, vdupq_n_u8(0x0d))),
        comparisonMask(vceqq_u8(bytes, vdupq_n_u8(0x0a)))
    };
#elif defined(__SSE2__)
    const __m128i bytes = _mm_loadu_si128(reinterpret_cast<const __m128i *>(source));
    auto comparisonMask = [&](uint8_t byte) -> uint16_t {
        return uint16_t(_mm_movemask_epi8(_mm_cmpeq_epi8(
            bytes,
            _mm_set1_epi8(char(byte))
        )));
    };
    return {
        comparisonMask(delimiter),
        comparisonMask(0x22),
        comparisonMask(0x0d),
        comparisonMask(0x0a)
    };
#else
    CSVByteMasks16 masks{};
    for (unsigned index = 0; index < 16; index++) {
        const uint16_t bit = uint16_t(1u << index);
        masks.delimiters |= source[index] == delimiter ? bit : 0;
        masks.quotes |= source[index] == 0x22 ? bit : 0;
        masks.carriageReturns |= source[index] == 0x0d ? bit : 0;
        masks.lineFeeds |= source[index] == 0x0a ? bit : 0;
    }
    return masks;
#endif
}

uint16_t prefixParity16(uint16_t bits) {
    bits ^= uint16_t(bits << 1);
    bits ^= uint16_t(bits << 2);
    bits ^= uint16_t(bits << 4);
    bits ^= uint16_t(bits << 8);
    return bits;
}

CSVUnquotedScanResult scanUntilUnquotedEvent(
    const uint8_t *source,
    uint64_t cursor,
    uint64_t length,
    uint8_t delimiter,
    bool atFieldStart
) {
    // Unusual delimiter choices use the exact scalar precedence of the public
    // state machine. The normal comma/tab/etc. path below skips every delimiter
    // without a branch while still detecting a quote immediately after one.
    if (delimiter == 0x22 || delimiter == 0x0d || delimiter == 0x0a) {
        while (cursor < length) {
            const uint8_t byte = source[cursor];
            if (atFieldStart && byte == 0x22) break;
            if (byte == delimiter) {
                atFieldStart = true;
                cursor++;
                continue;
            }
            if (byte == 0x0d || byte == 0x0a) break;
            atFieldStart = false;
            cursor++;
        }
        return {cursor, atFieldStart};
    }

#if defined(__aarch64__)
    const uint8x16_t delimiterVector = vdupq_n_u8(delimiter);
    const uint8x16_t quoteVector = vdupq_n_u8(0x22);
    const uint8x16_t carriageReturnVector = vdupq_n_u8(0x0d);
    const uint8x16_t lineFeedVector = vdupq_n_u8(0x0a);
    const uint8x8_t lowWeights = {1, 2, 4, 8, 16, 32, 64, 128};
    auto comparisonMask = [&](uint8x16_t comparison) -> uint16_t {
        const uint8x16_t bits = vshrq_n_u8(comparison, 7);
        return uint16_t(vaddv_u8(vmul_u8(vget_low_u8(bits), lowWeights)))
            | (uint16_t(vaddv_u8(vmul_u8(vget_high_u8(bits), lowWeights))) << 8);
    };
    while (cursor + 16 <= length) {
        const uint8x16_t bytes = vld1q_u8(source + cursor);
        const uint16_t delimiters = comparisonMask(vceqq_u8(bytes, delimiterVector));
        const uint16_t quotes = comparisonMask(vceqq_u8(bytes, quoteVector));
        const uint16_t lineEndings = comparisonMask(vorrq_u8(
            vceqq_u8(bytes, carriageReturnVector),
            vceqq_u8(bytes, lineFeedVector)
        ));
        const uint16_t fieldStarts = uint16_t(delimiters << 1)
            | uint16_t(atFieldStart ? 1 : 0);
        const uint16_t events = lineEndings | (quotes & fieldStarts);
        if (events != 0) {
            cursor += uint64_t(__builtin_ctz(unsigned(events)));
            return {cursor, source[cursor] == 0x22};
        }
        atFieldStart = (delimiters & 0x8000u) != 0;
        cursor += 16;
    }
#elif defined(__SSE2__)
    const __m128i delimiterVector = _mm_set1_epi8(char(delimiter));
    const __m128i quoteVector = _mm_set1_epi8(0x22);
    const __m128i carriageReturnVector = _mm_set1_epi8(0x0d);
    const __m128i lineFeedVector = _mm_set1_epi8(0x0a);
    while (cursor + 16 <= length) {
        const __m128i bytes = _mm_loadu_si128(
            reinterpret_cast<const __m128i *>(source + cursor)
        );
        const uint16_t delimiters = uint16_t(_mm_movemask_epi8(
            _mm_cmpeq_epi8(bytes, delimiterVector)
        ));
        const uint16_t quotes = uint16_t(_mm_movemask_epi8(
            _mm_cmpeq_epi8(bytes, quoteVector)
        ));
        const uint16_t lineEndings = uint16_t(_mm_movemask_epi8(_mm_or_si128(
            _mm_cmpeq_epi8(bytes, carriageReturnVector),
            _mm_cmpeq_epi8(bytes, lineFeedVector)
        )));
        const uint16_t fieldStarts = uint16_t(delimiters << 1)
            | uint16_t(atFieldStart ? 1 : 0);
        const uint16_t events = lineEndings | (quotes & fieldStarts);
        if (events != 0) {
            cursor += uint64_t(__builtin_ctz(unsigned(events)));
            return {cursor, source[cursor] == 0x22};
        }
        atFieldStart = (delimiters & 0x8000u) != 0;
        cursor += 16;
    }
#endif

    while (cursor < length) {
        const uint8_t byte = source[cursor];
        if (atFieldStart && byte == 0x22) break;
        if (byte == 0x0d || byte == 0x0a) break;
        atFieldStart = byte == delimiter;
        cursor++;
    }
    return {cursor, atFieldStart};
}

} // namespace

extern "C" LighTxtCSVScannerResult LighTxtScanCSVChunk(
    const uint8_t *source,
    uint64_t sourceLength,
    int64_t sourceBaseOffset,
    uint8_t delimiter,
    LighTxtCSVScannerState state,
    int64_t *checkpointOffsets,
    uint64_t checkpointCapacity
) {
    LighTxtCSVScannerResult result{};
    result.state = state;
    if ((!source && sourceLength != 0)
        || (!checkpointOffsets && checkpointCapacity != 0)
        || state.checkpointInterval == 0
        || sourceBaseOffset < 0
        || uint64_t(sourceBaseOffset) > uint64_t(INT64_MAX) - sourceLength) {
        result.status = LighTxtCSVScannerInvalidInput;
        return result;
    }

    uint64_t cursor = 0;
    uint64_t emitted = 0;
    auto emitPendingCheckpoint = [&]() -> bool {
        if (!result.state.checkpointPending) return true;
        if (result.state.completedRecords % result.state.checkpointInterval == 0) {
            if (emitted >= checkpointCapacity) return false;
            checkpointOffsets[emitted++] = result.state.recordStart;
        }
        result.state.checkpointPending = 0;
        return true;
    };

    // A prior LF may have filled the output exactly at a chunk boundary. CR is
    // intentionally deferred because a following LF belongs to the same row.
    if (!result.state.pendingCarriageReturn && !emitPendingCheckpoint()) {
        result.status = LighTxtCSVScannerCheckpointBufferFull;
        result.emittedCheckpointCount = emitted;
        return result;
    }

    while (cursor < sourceLength) {
        const uint8_t byte = source[cursor];
        const int64_t absolute = sourceBaseOffset + int64_t(cursor);

        if (result.state.pendingCarriageReturn) {
            result.state.pendingCarriageReturn = 0;
            if (byte == 0x0a) {
                result.state.recordStart = absolute + 1;
                cursor++;
                continue;
            }
        }
        if (!emitPendingCheckpoint()) {
            result.status = LighTxtCSVScannerCheckpointBufferFull;
            break;
        }

        // Process valid RFC-4180 runs as quote/newline masks. Every quote in a
        // quoted field toggles state, so doubled quotes naturally toggle twice;
        // delimiters need no scalar visit. Invalid unquoted literal quotes fall
        // through to the exact permissive scalar state machine below.
        if (delimiter != 0x22 && delimiter != 0x0d && delimiter != 0x0a
            && !result.state.pendingQuote && !result.state.pendingCarriageReturn
            && cursor + 16 <= sourceLength) {
            const CSVByteMasks16 masks = classifyCSVBytes16(source + cursor, delimiter);
            uint16_t insideAfter = prefixParity16(masks.quotes);
            if (result.state.inQuotedField) insideAfter = uint16_t(~insideAfter);
            const uint16_t lineEndings = masks.carriageReturns | masks.lineFeeds;
            const uint16_t permittedOpenings = uint16_t(
                (masks.delimiters | lineEndings | masks.quotes) << 1
            ) | uint16_t(result.state.atFieldStart ? 1 : 0);
            const uint16_t openingQuotes = masks.quotes & insideAfter;
            const uint16_t invalidOpenings = openingQuotes & uint16_t(~permittedOpenings);
            const uint16_t outsideLineEndings = lineEndings & uint16_t(~insideAfter);
            const uint16_t standaloneLineFeeds = masks.lineFeeds
                & uint16_t(~uint16_t(masks.carriageReturns << 1));
            const uint16_t recordEnds = outsideLineEndings
                & (masks.carriageReturns | standaloneLineFeeds);
            const uint64_t remainingOutput = checkpointCapacity - emitted;

            if (invalidOpenings == 0
                && uint64_t(__builtin_popcount(unsigned(recordEnds))) <= remainingOutput) {
                uint16_t pendingLineEndings = outsideLineEndings;
                while (pendingLineEndings != 0) {
                    const unsigned position = unsigned(
                        __builtin_ctz(unsigned(pendingLineEndings))
                    );
                    const uint16_t bit = uint16_t(1u << position);
                    pendingLineEndings &= uint16_t(~bit);
                    const int64_t lineEnd = sourceBaseOffset
                        + int64_t(cursor + position);
                    if ((masks.carriageReturns & bit) != 0) {
                        result.state.completedRecords++;
                        result.state.recordStart = lineEnd + 1;
                        result.state.checkpointPending =
                            result.state.completedRecords % result.state.checkpointInterval == 0;
                        if (position == 15) {
                            result.state.pendingCarriageReturn = 1;
                        } else if (source[cursor + position + 1] == 0x0a) {
                            result.state.recordStart++;
                            pendingLineEndings &= uint16_t(~uint16_t(bit << 1));
                            if (!emitPendingCheckpoint()) {
                                result.status = LighTxtCSVScannerCheckpointBufferFull;
                                break;
                            }
                        } else if (!emitPendingCheckpoint()) {
                            result.status = LighTxtCSVScannerCheckpointBufferFull;
                            break;
                        }
                    } else {
                        result.state.completedRecords++;
                        result.state.recordStart = lineEnd + 1;
                        result.state.checkpointPending =
                            result.state.completedRecords % result.state.checkpointInterval == 0;
                        if (!emitPendingCheckpoint()) {
                            result.status = LighTxtCSVScannerCheckpointBufferFull;
                            break;
                        }
                    }
                }
                if (result.status == LighTxtCSVScannerCheckpointBufferFull) break;

                const bool lastIsQuote = (masks.quotes & 0x8000u) != 0;
                const bool insideBeforeLast = (insideAfter & 0x4000u) != 0;
                if (lastIsQuote && insideBeforeLast) {
                    result.state.inQuotedField = 1;
                    result.state.pendingQuote = 1;
                } else {
                    result.state.inQuotedField = (insideAfter & 0x8000u) != 0;
                    result.state.pendingQuote = 0;
                }
                if (result.state.inQuotedField) {
                    result.state.atFieldStart = 0;
                } else {
                    const uint16_t lastBit = 0x8000u;
                    result.state.atFieldStart = (masks.delimiters & lastBit) != 0
                        || (outsideLineEndings & lastBit) != 0;
                }
                cursor += 16;
                continue;
            }
        }

        if (result.state.inQuotedField) {
            if (result.state.pendingQuote) {
                if (byte == 0x22) {
                    result.state.pendingQuote = 0;
                    cursor++;
                    continue;
                }
                result.state.inQuotedField = 0;
                result.state.pendingQuote = 0;
                // The current byte belongs to the delimiter/newline context.
            } else if (byte == 0x22) {
                result.state.pendingQuote = 1;
                cursor++;
                continue;
            } else {
                cursor = scanUntilByte(source, cursor, sourceLength, 0x22);
                continue;
            }
        }

        const CSVUnquotedScanResult unquoted = scanUntilUnquotedEvent(
            source,
            cursor,
            sourceLength,
            delimiter,
            result.state.atFieldStart
        );
        cursor = unquoted.cursor;
        result.state.atFieldStart = unquoted.atFieldStart;
        if (cursor == sourceLength) break;

        const uint8_t eventByte = source[cursor];
        const int64_t eventAbsolute = sourceBaseOffset + int64_t(cursor);
        if (result.state.atFieldStart && eventByte == 0x22) {
            result.state.inQuotedField = 1;
            result.state.pendingQuote = 0;
            result.state.atFieldStart = 0;
            cursor++;
            continue;
        }
        if (eventByte == 0x0a || eventByte == 0x0d) {
            result.state.completedRecords++;
            result.state.recordStart = eventAbsolute + 1;
            result.state.inQuotedField = 0;
            result.state.pendingQuote = 0;
            result.state.atFieldStart = 1;
            result.state.pendingCarriageReturn = eventByte == 0x0d;
            result.state.checkpointPending =
                result.state.completedRecords % result.state.checkpointInterval == 0;
            cursor++;
            if (eventByte == 0x0a && !emitPendingCheckpoint()) {
                result.status = LighTxtCSVScannerCheckpointBufferFull;
                break;
            }
            continue;
        }
        result.status = LighTxtCSVScannerInvalidInput;
        break;
    }

    result.processedByteCount = cursor;
    result.emittedCheckpointCount = emitted;
    return result;
}

static LighTxtJSONAcceleratorResult buildJSONContainerIndex(
    const uint8_t *source,
    uint64_t sourceLength,
    uint64_t sourceCapacity,
    LighTxtJSONContainerRecord *records,
    uint64_t recordCapacity,
    uint64_t maximumNestingDepth,
    LighTxtJSONAcceleratorProgress callback,
    void *context,
    bool forceNative64
) {
    LighTxtJSONAcceleratorResult result{};
    if (!source || !records || maximumNestingDepth == 0
        || maximumNestingDepth > (1u << 20)
        || sourceLength > LighTxtJSONAcceleratorMaximumSourceLength()) {
        result.status = LighTxtJSONAcceleratorUnsupportedSize;
        return result;
    }
    if (sourceCapacity < sourceLength
        || sourceCapacity - sourceLength < simdjson::SIMDJSON_PADDING) {
        result.status = LighTxtJSONAcceleratorInternalError;
        return result;
    }

    ProgressState progress{source, sourceLength, callback, context};
    const bool usesSIMDDocumentValidation = !forceNative64
        && sourceLength <= simdjson::SIMDJSON_MAXSIZE_BYTES;
    ValidationCounts validated;
    bool utf8Valid = true;
    error_code validationError = simdjson::SUCCESS;
    uint64_t validationNanoseconds = 0;
    std::thread validationThread;
    try {
        validationThread = std::thread([&] {
            const auto validationStarted = std::chrono::steady_clock::now();
            if (usesSIMDDocumentValidation) {
                simdjson::ondemand::parser parser;
                validationError = parser.allocate(
                    size_t(sourceLength),
                    size_t(std::max<uint64_t>(
                        simdjson::DEFAULT_MAX_DEPTH,
                        maximumNestingDepth + 8
                    ))
                );
                simdjson::ondemand::document document;
                if (!validationError) {
                    validationError = parser.iterate(
                        source,
                        size_t(sourceLength),
                        size_t(sourceCapacity)
                    ).get(document);
                }
                if (!validationError) {
                    simdjson::ondemand::value root;
                    validationError = document.get_value().get(root);
                    if (!validationError) {
                        validationError = validateValue(root, 0, validated, progress);
                    }
                    if (!validationError && !document.at_end()) {
                        validationError = simdjson::TAPE_ERROR;
                    }
                }
            } else {
                utf8Valid = simdjson::validate_utf8(
                    reinterpret_cast<const char *>(source),
                    size_t(sourceLength)
                );
            }
            if (!validationError && utf8Valid
                && !progress.publish(
                    0,
                    sourceLength,
                    validated.containers,
                    validated.values
                )) {
                validationError = simdjson::CAPACITY;
            }
            validationNanoseconds = uint64_t(
                std::chrono::duration_cast<std::chrono::nanoseconds>(
                    std::chrono::steady_clock::now() - validationStarted
                ).count()
            );
        });
    } catch (...) {
        result.status = LighTxtJSONAcceleratorInternalError;
        return result;
    }

    const auto buildStarted = std::chrono::steady_clock::now();
    bool built = false;
    try {
        built = usesSIMDDocumentValidation
            ? buildSIMDValidatedRecords(
                source,
                sourceLength,
                records,
                recordCapacity,
                maximumNestingDepth,
                progress,
                result
            )
            : buildStrictRecords(
                source,
                sourceLength,
                records,
                recordCapacity,
                maximumNestingDepth,
                progress,
                result
            );
    } catch (...) {
        progress.requestStop();
        validationThread.join();
        result.recordBuildNanoseconds = uint64_t(
            std::chrono::duration_cast<std::chrono::nanoseconds>(
                std::chrono::steady_clock::now() - buildStarted
            ).count()
        );
        result.validationNanoseconds = validationNanoseconds;
        result.status = LighTxtJSONAcceleratorInternalError;
        return result;
    }
    result.recordBuildNanoseconds = uint64_t(
        std::chrono::duration_cast<std::chrono::nanoseconds>(
            std::chrono::steady_clock::now() - buildStarted
        ).count()
    );
    if (!built) progress.requestStop();
    validationThread.join();
    result.validationNanoseconds = validationNanoseconds;
    if (!built) return result;

    if (progress.cancelled.load(std::memory_order_relaxed)) {
        result.status = LighTxtJSONAcceleratorCancelled;
        return result;
    }
    if (validationError || !utf8Valid) {
        result.status = LighTxtJSONAcceleratorInvalidJSON;
        return result;
    }
    if (usesSIMDDocumentValidation
        && (validated.containers != result.containerCount
            || validated.values != result.valueCount)) {
        result.status = LighTxtJSONAcceleratorInternalError;
    }
    return result;
}

extern "C" LighTxtJSONAcceleratorResult LighTxtBuildJSONContainerIndex(
    const uint8_t *source,
    uint64_t sourceLength,
    uint64_t sourceCapacity,
    LighTxtJSONContainerRecord *records,
    uint64_t recordCapacity,
    uint64_t maximumNestingDepth,
    LighTxtJSONAcceleratorProgress callback,
    void *context
) {
    return buildJSONContainerIndex(
        source,
        sourceLength,
        sourceCapacity,
        records,
        recordCapacity,
        maximumNestingDepth,
        callback,
        context,
        false
    );
}

extern "C" LighTxtJSONAcceleratorResult LighTxtBuildJSONContainerIndexNative64(
    const uint8_t *source,
    uint64_t sourceLength,
    uint64_t sourceCapacity,
    LighTxtJSONContainerRecord *records,
    uint64_t recordCapacity,
    uint64_t maximumNestingDepth,
    LighTxtJSONAcceleratorProgress callback,
    void *context
) {
    return buildJSONContainerIndex(
        source,
        sourceLength,
        sourceCapacity,
        records,
        recordCapacity,
        maximumNestingDepth,
        callback,
        context,
        true
    );
}
