#include "steering_kernel.h"
#include "flow_field_server.h"
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

void SteeringKernel::tick(float /*delta*/) {
    // Implemented in PF-A-13.
}

} // namespace drossfront
