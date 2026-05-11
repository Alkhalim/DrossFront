#pragma once
#include <godot_cpp/classes/object.hpp>
#include <godot_cpp/variant/vector2i.hpp>
#include <godot_cpp/variant/vector3.hpp>
#include "types.h"
#include "steering_kernel_impl.h"

namespace drossfront {

class FlowFieldServer;

class SteeringKernel : public godot::Object {
    GDCLASS(SteeringKernel, godot::Object)

protected:
    static void _bind_methods();

public:
    // Re-export impl's PathFailureReason so GDScript bindings remain on the
    // wrapper class. Values must match SteeringKernelImpl::PathFailureReason.
    enum PathFailureReason {
        PATH_FAILURE_NONE             = SteeringKernelImpl::PATH_FAILURE_NONE,
        PATH_FAILURE_REPEATEDLY_STUCK = SteeringKernelImpl::PATH_FAILURE_REPEATEDLY_STUCK,
    };

    SteeringKernel();
    ~SteeringKernel();

    // Accepts a godot::Object* so this can be GDScript-bound; we cast_to
    // FlowFieldServer internally. Exposing the typed pointer to GDScript
    // would require Godot to know how to marshal FlowFieldServer*, which
    // it can't (no Variant conversion); Object* is the universal handle.
    void set_flow_field_server(godot::Object *server_obj);

    AgentHandle register_agent(int unit_id, int agent_class, float radius,
                                float max_speed, float max_accel, float max_turn_rate)
        { return impl_.register_agent(unit_id, agent_class, radius, max_speed, max_accel, max_turn_rate); }
    void unregister_agent(AgentHandle handle)
        { impl_.unregister_agent(handle); }
    void set_agent_pos(AgentHandle handle, godot::Vector3 world_pos)
        { impl_.set_agent_pos(handle, world_pos); }
    void set_agent_target(AgentHandle handle, int group_id, FieldId field_id, int stance)
        { impl_.set_agent_target(handle, group_id, field_id, stance); }
    void set_agent_flag(AgentHandle handle, int flag, bool value)
        { impl_.set_agent_flag(handle, flag, value); }
    void set_agent_speed_cap(AgentHandle handle, float cap)
        { impl_.set_agent_speed_cap(handle, cap); }
    void set_agent_target_pos(AgentHandle handle, godot::Vector3 target_pos)
        { impl_.set_agent_target_pos(handle, target_pos); }
    godot::Vector3 get_velocity(AgentHandle handle)
        { return impl_.get_velocity(handle); }
    void tick(float delta)
        { impl_.tick(delta); }

    AgentHandle pop_path_unreachable_event(int *out_reason)
        { return impl_.pop_path_unreachable_event(out_reason); }
    godot::Vector2i pop_path_unreachable_event_v()
        { return impl_.pop_path_unreachable_event_v(); }

    int agent_count() const { return impl_.agent_count(); }

private:
    SteeringKernelImpl impl_;
};

} // namespace drossfront
