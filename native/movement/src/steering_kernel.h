#pragma once
#include <godot_cpp/classes/object.hpp>
#include <godot_cpp/variant/vector3.hpp>
#include "types.h"
#include "agent.h"

namespace drossfront {

class FlowFieldServer;

class SteeringKernel : public godot::Object {
    GDCLASS(SteeringKernel, godot::Object)

protected:
    static void _bind_methods();

public:
    SteeringKernel();
    ~SteeringKernel();

    void set_flow_field_server(FlowFieldServer *server) { server_ = server; }

    AgentHandle register_agent(int unit_id, int agent_class, float radius,
                                float max_speed, float max_accel, float max_turn_rate);
    void unregister_agent(AgentHandle handle);
    void set_agent_pos(AgentHandle handle, godot::Vector3 world_pos);
    void set_agent_target(AgentHandle handle, int group_id, FieldId field_id, int stance);
    void set_agent_flag(AgentHandle handle, int flag, bool value);
    godot::Vector3 get_velocity(AgentHandle handle);
    void tick(float delta);

    int agent_count() const { return agents_.count; }

private:
    AgentSoA agents_;
    FlowFieldServer *server_ = nullptr;

    int handle_to_idx(AgentHandle h) const { return static_cast<int>(h) - 1; }
    AgentHandle idx_to_handle(int idx) const { return static_cast<AgentHandle>(idx) + 1; }
};

} // namespace drossfront
