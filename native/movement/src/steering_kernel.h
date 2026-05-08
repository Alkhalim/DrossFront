#pragma once
#include <godot_cpp/classes/object.hpp>
#include <godot_cpp/variant/vector3.hpp>
#include "types.h"

namespace drossfront {

class SteeringKernel : public godot::Object {
    GDCLASS(SteeringKernel, godot::Object)

protected:
    static void _bind_methods();

public:
    SteeringKernel();
    ~SteeringKernel();

    // API exposed to GDScript. Stubs in this task — implemented in Phase 3.
    AgentHandle register_agent(int unit_id, int agent_class, float radius,
                                float max_speed, float max_accel, float max_turn_rate);
    void unregister_agent(AgentHandle handle);
    void set_agent_pos(AgentHandle handle, godot::Vector3 world_pos);
    void set_agent_target(AgentHandle handle, int group_id, FieldId field_id, int stance);
    void set_agent_flag(AgentHandle handle, int flag, bool value);
    godot::Vector3 get_velocity(AgentHandle handle);
    void tick(float delta);
};

} // namespace drossfront
