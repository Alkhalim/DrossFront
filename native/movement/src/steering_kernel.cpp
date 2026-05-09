#include "steering_kernel.h"
#include "flow_field_server.h"
#include <godot_cpp/core/class_db.hpp>

namespace {
    // Tunables — match spec §12.
    // SEPARATE_BUFFER is the slack added on top of the summed agent radii
    // before separation force kicks in. Two large agents (radius 2.4 each)
    // need ~4.8m to not overlap physically; with a 0.6m buffer separation
    // engages at 5.4m — comfortably wider than the bodies. Two small
    // agents (radius 1.0 each) get 2.6m — close to the previous constant
    // 2.5m so small-unit behavior is unchanged.
    constexpr float SEPARATE_BUFFER        = 0.6f;
    // Reduced from 6.0 — at peak (touching contact) the previous repel
    // produced a per-tick lateral kick large enough that the inertia
    // integrator could flip lateral velocity every tick when two units
    // ran roughly parallel (one tick they were on your right, next tick
    // on your left), driving a visible left-right wiggle within groups.
    // 3.0 keeps separation effective at preventing overlap but soft
    // enough that the integrator can't reverse lateral motion in one
    // tick at typical group speeds.
    constexpr float SEPARATE_REPEL         = 3.0f;
    // Hard cap on the per-tick separation contribution. Without this,
    // a unit caught between two others can accumulate sep up to
    // SEPARATE_REPEL × 2 (one push from each peer), and at peak that's
    // enough to overshoot the centerline and ricochet — same wiggle
    // pattern. Cap at half max_speed so separation can nudge a unit
    // sideways without ever reversing its forward motion.
    constexpr float SEPARATE_MAX_FRACTION  = 0.5f;
    constexpr float AVOID_DISTANCE         = 3.0f;     // unused in PF-A (no buildings list yet)
    constexpr float AVOID_REPEL            = 24.0f;
    // Cohesion as a fraction of the unit's own max_speed. A 5 m/s hound
    // gets 1.5 m/s pull, a 2 m/s crawler 0.6 m/s. Without per-unit scaling
    // a constant 2 m/s cohesion was 40% of a hound's speed but ~100% of a
    // crawler's, leaving slow chassis dragged everywhere by the centroid.
    constexpr float COHESION_FRACTION      = 0.3f;
    // Cohesion deadband — no pull when the unit is already within this
    // distance of the group centroid. Avoids the "always drifting toward
    // the middle" pile-up that made mixed-size groups bump constantly.
    // Within deadband, only SEPARATE acts — so units settle into their
    // natural body-radius spacing instead of stacking on the centroid.
    constexpr float COHESION_DEADBAND      = 4.0f;
    constexpr float COHESION_QUERY_RADIUS  = 16.0f;    // unused in PF-A (no group centroid yet)
}

namespace drossfront {

void SteeringKernel::_bind_methods() {
#ifndef MOVEMENT_NATIVE_TESTS
    // See FlowFieldServer::_bind_methods for the rationale on the
    // MOVEMENT_NATIVE_TESTS guard. Tests call C++ methods directly.
    using namespace godot;
    ClassDB::bind_method(D_METHOD("register_agent", "unit_id", "agent_class", "radius",
                                  "max_speed", "max_accel", "max_turn_rate"),
                         &SteeringKernel::register_agent);
    ClassDB::bind_method(D_METHOD("unregister_agent", "handle"),
                         &SteeringKernel::unregister_agent);
    ClassDB::bind_method(D_METHOD("set_agent_pos", "handle", "world_pos"),
                         &SteeringKernel::set_agent_pos);
    ClassDB::bind_method(D_METHOD("set_agent_target", "handle", "group_id", "field_id", "stance"),
                         &SteeringKernel::set_agent_target);
    ClassDB::bind_method(D_METHOD("set_agent_flag", "handle", "flag", "value"),
                         &SteeringKernel::set_agent_flag);
    ClassDB::bind_method(D_METHOD("get_velocity", "handle"),
                         &SteeringKernel::get_velocity);
    ClassDB::bind_method(D_METHOD("tick", "delta"),
                         &SteeringKernel::tick);
    ClassDB::bind_method(D_METHOD("set_flow_field_server", "server"),
                         &SteeringKernel::set_flow_field_server);
#endif
}

void SteeringKernel::set_flow_field_server(godot::Object *server_obj) {
    server_ = godot::Object::cast_to<FlowFieldServer>(server_obj);
}

SteeringKernel::SteeringKernel() {}
SteeringKernel::~SteeringKernel() {}

AgentHandle SteeringKernel::register_agent(int /*unit_id*/, int agent_class, float radius,
                                            float max_speed, float max_accel, float max_turn_rate) {
    int idx = agents_.allocate_slot();
    agents_.agent_class[idx] = static_cast<uint8_t>(agent_class);
    agents_.radius[idx] = radius;
    agents_.max_speed[idx] = max_speed;
    agents_.max_accel[idx] = max_accel;
    agents_.max_turn_rate[idx] = max_turn_rate;
    agents_.flags[idx] = 0;
    agents_.field_id[idx] = INVALID_FIELD_ID;
    agents_.vel[idx] = {};
    return idx_to_handle(idx);
}

void SteeringKernel::unregister_agent(AgentHandle handle) {
    int idx = handle_to_idx(handle);
    if (idx < 0 || idx >= agents_.count) return;
    agents_.free_slot(idx);
}

void SteeringKernel::set_agent_pos(AgentHandle handle, godot::Vector3 world_pos) {
    int idx = handle_to_idx(handle);
    if (idx < 0 || idx >= agents_.count || !agents_.alive[idx]) return;
    agents_.pos[idx] = world_pos;
}

void SteeringKernel::set_agent_target(AgentHandle handle, int group_id, FieldId field_id, int /*stance*/) {
    int idx = handle_to_idx(handle);
    if (idx < 0 || idx >= agents_.count || !agents_.alive[idx]) return;
    agents_.group_id[idx] = static_cast<uint32_t>(group_id);
    agents_.field_id[idx] = field_id;
    agents_.flags[idx] |= AGENT_FLAG_HAS_TARGET;
    // Any new target acquisition clears HALTED — a halted unit being given
    // a target should walk again. Avoids requiring every caller (goto_world,
    // GroupAura.setup, combat-driven re-issue) to remember to clear the flag.
    agents_.flags[idx] &= static_cast<uint8_t>(~AGENT_FLAG_HALTED);
}

void SteeringKernel::set_agent_flag(AgentHandle handle, int flag, bool value) {
    int idx = handle_to_idx(handle);
    if (idx < 0 || idx >= agents_.count || !agents_.alive[idx]) return;
    if (value) agents_.flags[idx] |= static_cast<uint8_t>(flag);
    else       agents_.flags[idx] &= static_cast<uint8_t>(~flag);
}

godot::Vector3 SteeringKernel::get_velocity(AgentHandle handle) {
    int idx = handle_to_idx(handle);
    if (idx < 0 || idx >= agents_.count || !agents_.alive[idx]) return {};
    return agents_.vel[idx];
}

void SteeringKernel::tick(float delta) {
    if (!server_) return;
    const int N = agents_.count;

    for (int i = 0; i < N; ++i) {
        if (!agents_.alive[i]) continue;
        uint8_t f = agents_.flags[i];
        if (!(f & AGENT_FLAG_HAS_TARGET)) continue;
        if (f & (AGENT_FLAG_PARALYZED | AGENT_FLAG_HALTED)) {
            // Spec §6: halt zeroes velocity. Otherwise the orchestrator's
            // get_velocity() call would keep applying the agent's last
            // computed velocity via move_and_slide, drifting forever
            // until something else cleared the flag.
            agents_.vel[i] = {};
            continue;
        }

        godot::Vector3 pos = agents_.pos[i];
        float max_speed = agents_.max_speed[i];

        // SEEK from flow field (or aircraft direct seek; PF-A: ground only,
        // so we always sample). Aircraft branch lands in PF-B.
        godot::Vector2 flow = server_->sample(agents_.field_id[i], pos);
        godot::Vector3 seek(flow.x * max_speed, 0.0f, flow.y * max_speed);

        // Arrival (or unreachable goal): the field returns (0,0) flow at
        // the goal cell itself AND at any cell that's disconnected from
        // the goal. In both cases the agent should stop trying to drive
        // toward the goal — no SEEK, no COHESION pulling toward the
        // group centroid (which would cause stutter-step at the
        // destination). Keep SEPARATE so peers maintain spacing instead
        // of stacking on a single point. With seek=0 and coh=0, sep
        // decays to zero once peers are at SEPARATE_DISTANCE apart, and
        // inertia takes velocity to zero. Final state: units settle in
        // a small cluster around the goal, standing still.
        bool at_goal_or_unreachable = (flow.length_squared() < 0.0001f);
        if (at_goal_or_unreachable) {
            seek = godot::Vector3();
        }

        // SEPARATE pass — pairwise O(N^2). Acceptable at PF-A scale (one
        // squad type pilot, < 50 agents). PF-C swaps in SpatialIndex via a
        // GDScript-callable bridge.
        // Per-pair separation distance: summed agent radii + SEPARATE_BUFFER.
        // Without this, a constant SEPARATE_DISTANCE meant two large agents
        // (radius 2.4 each) only repelled within 2.5m even though their
        // physical bodies overlap until 4.8m+ apart — they constantly
        // bumped each other in mixed-size groups.
        const float my_radius = agents_.radius[i];
        godot::Vector3 sep = {};
        for (int j = 0; j < N; ++j) {
            if (j == i || !agents_.alive[j]) continue;
            godot::Vector3 dp = pos - agents_.pos[j];
            dp.y = 0.0f;
            float d = dp.length();
            float min_dist = my_radius + agents_.radius[j] + SEPARATE_BUFFER;
            if (d <= 0.001f || d > min_dist) continue;
            float strength = SEPARATE_REPEL * (1.0f - d / min_dist);
            sep += dp.normalized() * strength;
        }
        // Cap separation magnitude so a unit caught between two peers
        // (each contributing repel) can't accumulate enough force to
        // reverse its forward motion. See SEPARATE_MAX_FRACTION doc.
        float sep_len = sep.length();
        float sep_cap = max_speed * SEPARATE_MAX_FRACTION;
        if (sep_len > sep_cap) sep *= (sep_cap / sep_len);

        // COHESION — toward same-group centroid (computed on the fly here;
        // GroupAura caches it later when wired up via group_id lookup tables).
        // Skipped on arrival so it doesn't fight SEPARATE at the destination.
        // Two refinements over the original constant cap:
        //   - Deadband: no cohesion when within COHESION_DEADBAND of centroid.
        //     Prevents the "always pulling toward middle" pile-up that made
        //     mixed-size groups bump into each other constantly.
        //   - Fraction of own max_speed: a 5 m/s hound gets up to 1.5 m/s
        //     pull, a 2 m/s crawler 0.6 m/s. The previous absolute 2 m/s cap
        //     dragged slow chassis around at full speed.
        godot::Vector3 coh = {};
        if (!at_goal_or_unreachable) {
            godot::Vector3 centroid = {};
            int peers = 0;
            for (int j = 0; j < N; ++j) {
                if (j == i || !agents_.alive[j]) continue;
                if (agents_.group_id[j] != agents_.group_id[i]) continue;
                centroid += agents_.pos[j];
                ++peers;
            }
            if (peers > 0) {
                centroid /= static_cast<float>(peers);
                coh = centroid - pos;
                coh.y = 0.0f;
                float clen = coh.length();
                if (clen <= COHESION_DEADBAND) {
                    coh = godot::Vector3();
                } else {
                    // Push effective magnitude down by the deadband so the
                    // gradient is continuous at the boundary instead of
                    // stepping from 0 to full pull.
                    float effective = clen - COHESION_DEADBAND;
                    float cohesion_max = max_speed * COHESION_FRACTION;
                    if (effective > cohesion_max) effective = cohesion_max;
                    coh = (coh / clen) * effective;
                }
            }
        }

        // Compose; clamp to max_speed.
        godot::Vector3 desired = seek + sep + coh;
        desired.y = 0.0f;
        float dlen = desired.length();
        if (dlen > max_speed) desired *= (max_speed / dlen);

        // Inertia: linear interpolation toward desired bounded by max_accel.
        godot::Vector3 v = agents_.vel[i];
        godot::Vector3 dv = desired - v;
        float dvlen = dv.length();
        float max_dv = agents_.max_accel[i] * delta;
        if (dvlen > max_dv) dv *= (max_dv / dvlen);
        v += dv;
        agents_.vel[i] = v;
    }
}

} // namespace drossfront
