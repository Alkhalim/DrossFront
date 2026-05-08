#include "steering_kernel.h"
#include <godot_cpp/core/class_db.hpp>

namespace drossfront {

void SteeringKernel::_bind_methods() {
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
}

SteeringKernel::SteeringKernel() {}
SteeringKernel::~SteeringKernel() {}

AgentHandle SteeringKernel::register_agent(int, int, float, float, float, float) {
    return INVALID_AGENT_HANDLE;
}
void SteeringKernel::unregister_agent(AgentHandle) {}
void SteeringKernel::set_agent_pos(AgentHandle, godot::Vector3) {}
void SteeringKernel::set_agent_target(AgentHandle, int, FieldId, int) {}
void SteeringKernel::set_agent_flag(AgentHandle, int, bool) {}
godot::Vector3 SteeringKernel::get_velocity(AgentHandle) { return godot::Vector3(); }
void SteeringKernel::tick(float) {}

} // namespace drossfront
