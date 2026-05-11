#include "steering_kernel.h"
#include "flow_field_server.h"
#include <godot_cpp/core/class_db.hpp>

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
    ClassDB::bind_method(D_METHOD("pop_path_unreachable_event"),
                         &SteeringKernel::pop_path_unreachable_event_v);
#endif
}

void SteeringKernel::set_flow_field_server(godot::Object *server_obj) {
    FlowFieldServer *fs = godot::Object::cast_to<FlowFieldServer>(server_obj);
    impl_.set_flow_field_server(fs ? &fs->impl() : nullptr);
}

SteeringKernel::SteeringKernel() {}
SteeringKernel::~SteeringKernel() {}

} // namespace drossfront
