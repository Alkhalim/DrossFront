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

    AgentHandle register_agent(int unit_id, int agent_class, float radius,
                                float max_speed, float max_accel, float max_turn_rate);
    void unregister_agent(AgentHandle handle);
    void set_agent_pos(AgentHandle handle, godot::Vector3 world_pos);
    void set_agent_target(AgentHandle handle, int group_id, FieldId field_id, int stance);
    void set_agent_flag(AgentHandle handle, int flag, bool value);
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
