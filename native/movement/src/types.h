#pragma once
#include <cstdint>

namespace drossfront {

using FieldId = uint32_t;
using AgentHandle = uint32_t;

constexpr FieldId INVALID_FIELD_ID = 0;
constexpr AgentHandle INVALID_AGENT_HANDLE = 0;

enum AgentClass : uint8_t {
    AGENT_CLASS_SMALL = 0,
    AGENT_CLASS_MEDIUM = 1,
    AGENT_CLASS_LARGE = 2,
    AGENT_CLASS_COUNT = 3,
};

enum AgentFlag : uint8_t {
    AGENT_FLAG_HAS_TARGET = 1 << 0,
    AGENT_FLAG_PARALYZED  = 1 << 1,
    AGENT_FLAG_HALTED     = 1 << 2,
    AGENT_FLAG_IS_AIRCRAFT = 1 << 3,
    AGENT_FLAG_ENGAGED_IN_COMBAT = 1 << 4,
    AGENT_FLAG_STUCK_PUSHOUT     = 1 << 5,  // L1 push-out is active
    AGENT_FLAG_ARRIVED           = 1 << 6,  // unit is within arrival zone; SEEK = 0, SEPARATE still applies
};

} // namespace drossfront
