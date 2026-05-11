#pragma once
#include <array>
#include <limits>
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
    std::vector<float>          speed_cap;   // convoy cap — effective max_speed = min(max_speed, speed_cap). INF = no cap.
    std::vector<float>          max_accel;
    std::vector<float>          max_turn_rate;
    std::vector<float>          radius;
    std::vector<uint8_t>        flags;
    std::vector<uint8_t>        agent_class;
    // Stuck detector — see steering_kernel.cpp tick().
    std::vector<godot::Vector3> prev_pos;                // last tick's pos for displacement
    std::vector<float>          stuck_window_sum;        // running sum of last STUCK_WINDOW_TICKS displacements
    std::vector<int>            stuck_window_count;      // tick count populating the window (capped at STUCK_WINDOW_TICKS)
    std::vector<int>            stuck_window_head;       // ring-buffer index for next write
    std::vector<std::array<float, 32>> stuck_window;     // ring buffer; size 32 = pow2 above STUCK_WINDOW_TICKS (currently 20). Grow this if the window ever exceeds 32.
    std::vector<int>            stuck_pushout_frames_left;
    std::vector<godot::Vector3> stuck_pushout_dir;
    std::vector<float>          stuck_cooldown_remaining; // seconds until next escalation allowed
    std::vector<uint8_t>        stuck_level;             // 0 = clear, 1 = L1 fired, 2 = L2 fired (terminal)
    std::vector<bool>           alive;          // false = slot recyclable
    int count = 0;

    int allocate_slot() {
        for (int i = 0; i < count; ++i) {
            if (!alive[i]) {
                alive[i] = true;
                // Clear stuck-detector state so a recycled slot doesn't
                // inherit the prior occupant's escalation history.
                prev_pos[i] = {};
                stuck_window_sum[i] = 0.0f;
                stuck_window_count[i] = 0;
                stuck_window_head[i] = 0;
                stuck_window[i].fill(0.0f);
                stuck_pushout_frames_left[i] = 0;
                stuck_pushout_dir[i] = {};
                stuck_cooldown_remaining[i] = 0.0f;
                stuck_level[i] = 0;
                // Recycle: reset convoy cap so the new occupant starts uncapped.
                speed_cap[i] = std::numeric_limits<float>::infinity();
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
        speed_cap.push_back(std::numeric_limits<float>::infinity());
        max_accel.push_back(0.0f);
        max_turn_rate.push_back(0.0f);
        radius.push_back(0.0f);
        flags.push_back(0);
        agent_class.push_back(0);
        prev_pos.push_back({});
        stuck_window_sum.push_back(0.0f);
        stuck_window_count.push_back(0);
        stuck_window_head.push_back(0);
        stuck_window.push_back(std::array<float, 32>{});  // brace-init zeros all 32 floats
        stuck_pushout_frames_left.push_back(0);
        stuck_pushout_dir.push_back({});
        stuck_cooldown_remaining.push_back(0.0f);
        stuck_level.push_back(0);
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
