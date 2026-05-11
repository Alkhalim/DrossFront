#pragma once
#include <vector>
#include <godot_cpp/variant/vector2i.hpp>
#include <godot_cpp/variant/vector3.hpp>
#include "types.h"
#include "agent.h"

namespace drossfront {

class FlowFieldServerImpl;

class SteeringKernelImpl {
public:
    SteeringKernelImpl();
    ~SteeringKernelImpl();

    // Reason codes written into PathFailureEvent and surfaced via
    // pop_path_unreachable_event. The wrapper class SteeringKernel re-exports
    // these as its own PathFailureReason enum so GDScript bindings stay on the
    // wrapper; the values must match MovementComponent constants.
    enum PathFailureReason {
        PATH_FAILURE_NONE = 0,              // sentinel — queue empty
        PATH_FAILURE_REPEATEDLY_STUCK = 2,  // matches MovementComponent.REASON_REPEATEDLY_STUCK
    };

    AgentHandle register_agent(int unit_id, int agent_class, float radius,
                                float max_speed, float max_accel, float max_turn_rate);
    void unregister_agent(AgentHandle handle);
    void set_agent_pos(AgentHandle handle, godot::Vector3 world_pos);
    void set_agent_target(AgentHandle handle, int group_id, FieldId field_id, int stance);
    void set_agent_flag(AgentHandle handle, int flag, bool value);
    // Convoy speed cap — per spec §4. Sets the effective max_speed upper bound
    // for this agent. Pass std::numeric_limits<float>::infinity() to clear (no cap).
    // GroupAura.setup applies min(max_speed across members) to all ground members;
    // _exit_tree resets to INF so dispersed squads recover their own speed.
    void set_agent_speed_cap(AgentHandle handle, float cap);
    // Aircraft / drone direct-seek target. Sets HAS_TARGET, clears HALTED,
    // resets stuck detector (same semantics as set_agent_target since
    // re-issuing a target should give the agent a fresh escalation window).
    // Doesn't touch field_id (aircraft don't sample fields). Caller should
    // also set AGENT_FLAG_IS_AIRCRAFT once via set_agent_flag at
    // registration time (B3 wires this from AircraftMovement).
    void set_agent_target_pos(AgentHandle handle, godot::Vector3 target_pos);
    godot::Vector3 get_velocity(AgentHandle handle);
    void tick(float delta);

    // Drain the per-tick event queue. Returns the AgentHandle of the next
    // pending failure (or 0 if the queue is empty). Reason is written to
    // *out_reason. Designed for a simple drain loop:
    //   int reason = 0;
    //   while (AgentHandle h = kernel.pop_path_unreachable_event(&reason)) { ... }
    //
    // GDScript can't take output pointers, so the GDScript-bound wrapper
    // pop_path_unreachable_event_v() returns Vector2i(handle, reason)
    // with (0, 0) signalling empty queue.
    AgentHandle pop_path_unreachable_event(int *out_reason);
    godot::Vector2i pop_path_unreachable_event_v();

    void set_flow_field_server(FlowFieldServerImpl *server);

    int agent_count() const { return agents_.count; }

#ifdef MOVEMENT_NATIVE_TESTS
    float test_get_progress_ratio(int idx, float delta) const;
    int   test_get_stuck_level(int idx) const { return agents_.stuck_level[idx]; }
    int   test_get_pushout_frames(int idx) const { return agents_.stuck_pushout_frames_left[idx]; }
    int   test_pending_failure_count() const { return static_cast<int>(pending_failures_.size()); }
    int   test_handle_to_idx(AgentHandle h) const { return handle_to_idx(h); }
    godot::Vector3 test_get_pos(int idx) const { return agents_.pos[idx]; }
#endif

private:
    struct PathFailureEvent {
        AgentHandle handle;
        int reason;
    };
    std::vector<PathFailureEvent> pending_failures_;

    AgentSoA agents_;
    FlowFieldServerImpl *server_ = nullptr;

    int handle_to_idx(AgentHandle h) const { return static_cast<int>(h) - 1; }
    AgentHandle idx_to_handle(int idx) const { return static_cast<AgentHandle>(idx) + 1; }
};

} // namespace drossfront
