#pragma once
#include <vector>
#include <cstdint>
#include <godot_cpp/variant/vector3.hpp>
#include "types.h"

namespace drossfront {

struct AgentSoA {
    std::vector<godot::Vector3> pos;
    std::vector<godot::Vector3> vel;
    std::vector<godot::Vector3> target_pos;     // for aircraft direct-seek
    std::vector<uint32_t>       group_id;
    std::vector<FieldId>        field_id;
    std::vector<float>          max_speed;
    std::vector<float>          max_accel;
    std::vector<float>          max_turn_rate;
    std::vector<float>          radius;
    std::vector<uint8_t>        flags;
    std::vector<uint8_t>        agent_class;
    std::vector<bool>           alive;          // false = slot recyclable
    int count = 0;

    int allocate_slot() {
        for (int i = 0; i < count; ++i) {
            if (!alive[i]) {
                alive[i] = true;
                return i;
            }
        }
        // Grow.
        int idx = count;
        ++count;
        pos.push_back({});
        vel.push_back({});
        target_pos.push_back({});
        group_id.push_back(0);
        field_id.push_back(INVALID_FIELD_ID);
        max_speed.push_back(0.0f);
        max_accel.push_back(0.0f);
        max_turn_rate.push_back(0.0f);
        radius.push_back(0.0f);
        flags.push_back(0);
        agent_class.push_back(0);
        alive.push_back(true);
        return idx;
    }

    void free_slot(int idx) {
        if (idx >= 0 && idx < count) {
            alive[idx] = false;
            flags[idx] = 0;
            field_id[idx] = INVALID_FIELD_ID;
            vel[idx] = {};
        }
    }
};

} // namespace drossfront
